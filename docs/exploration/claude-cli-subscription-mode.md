# Exploratie: Claude CLI Subscription Mode als Hoofdagent

## Samenvatting

Dit document onderzoekt de haalbaarheid van een "subscription mode" waarbij NullClaw
een persistente Claude CLI sessie start en deze als hoofdagent gebruikt, als alternatief
voor directe API-koppelingen.

## Huidige Situatie

### Bestaande Claude CLI Provider

`src/providers/claude_cli.zig` implementeert een **spawn-per-request** model:

```
Gebruiker → Agent → ClaudeCliProvider → spawn `claude -p <prompt>` → wacht → parse → exit
```

**Beperkingen:**
- Elk verzoek spawnt een nieuw `claude` proces (cold start ~1-3s)
- Geen gesprekscontext: alleen het laatste user-bericht wordt doorgestuurd
- Geen native tool support (`supportsNativeTools = false`)
- Geen streaming (`stream_chat` niet geïmplementeerd)
- Geen vision support
- Geen token tracking (geen usage-velden in CLI output)

### Provider Architectuur

Alle providers implementeren dezelfde `Provider.VTable` interface:

| Methode | Vereist | Beschrijving |
|---|---|---|
| `chat` | Ja | Request → ChatResponse (met tool_calls, usage) |
| `chatWithSystem` | Ja | Simpele prompt met systeem-instructie |
| `supportsNativeTools` | Ja | Tool call support |
| `getName` | Ja | Provider naam |
| `deinit` | Ja | Cleanup |
| `stream_chat` | Optioneel | SSE-achtige streaming met callback |
| `supports_vision` | Optioneel | Multimodal support |
| `warmup` | Optioneel | Pre-connectie |

De `ProviderHolder` tagged union in `factory.zig` bevat al een `claude_cli` variant.

## Wat is "Subscription Mode"?

Het idee: in plaats van per-request te betalen via de API, gebruik je een bestaand
Claude Pro/Max/Team abonnement via de Claude CLI als **persistente sessie**.

### Voordelen

1. **Kostenmodel**: Vast maandelijks abonnement i.p.v. per-token API kosten
2. **Geen API key nodig**: Claude CLI gebruikt OAuth/browser-auth
3. **Toegang tot nieuwste modellen**: Max-abonnement geeft toegang tot Opus etc.
4. **Extended thinking**: Claude CLI heeft native extended thinking support
5. **Eenvoudige setup**: `claude login` is eenvoudiger dan API key management

### Uitdagingen

1. **Rate limits**: Abonnementen hebben zachte rate limits (niet gedocumenteerd)
2. **ToS**: Automated/programmatic gebruik via CLI is mogelijk in strijd met Terms of Service
3. **Geen SLA**: Geen uptime-garanties zoals bij de API
4. **Sessie-management**: CLI sessies kunnen timeout'en of disconnecten

## Technische Aanpak: Drie Opties

### Optie A: Persistent Subprocess met Stdin/Stdout Pipes

```
NullClaw ←→ [stdin pipe] → claude --interactive → [stdout pipe] ←→ NullClaw
               ↑                                        ↑
          JSON requests                          JSON responses
```

**Concept**: Start `claude` in interactieve modus met `--output-format stream-json`
en houd het proces in leven. Stuur berichten via stdin, lees antwoorden via stdout.

**Voordelen:**
- Gesprekscontext behouden binnen de Claude CLI sessie
- Geen cold start overhead per request
- Potentieel streaming via stdout pipe-reading

**Nadelen:**
- Claude CLI's interactieve modus is ontworpen voor terminal-gebruik, niet voor pipe-based IPC
- Geen gestructureerd protocol voor request/response multiplexing
- Stdout parsing is fragiel (mixed status/content output)
- Subprocess lifecycle management is complex (heartbeats, reconnects, crash recovery)
- Claude CLI kan intern state hebben die interfereert (command buffer, history)

**Geschatte complexiteit**: Hoog. Vereist reverse-engineering van CLI gedrag.

### Optie B: Claude CLI SDK/API Mode (Aanbevolen)

```
NullClaw ←→ ClaudeCliSubscriptionProvider ←→ `claude api` subcommands
```

**Concept**: Gebruik `claude` CLI's eigen SDK subcommands (`claude api`) die
een stabielere interface bieden dan de interactieve modus.

Claude Code biedt het `claude` commando met:
- `claude -p "prompt"` — Eenmalig verzoek (huidige implementatie)
- `claude --resume <session-id>` — Sessie hervatten
- `claude --continue` — Laatste sessie voortzetten
- `claude --output-format stream-json` — Gestructureerde JSON output

**Implementatie als SubscriptionProvider:**

```zig
pub const ClaudeCliSubscriptionProvider = struct {
    allocator: std.mem.Allocator,
    model: []const u8,
    session_id: ?[]const u8,          // Persistent sessie-ID
    conversation_history: MessageHistory, // Lokale history voor context

    pub fn chat(self, allocator, request, model, temp) !ChatResponse {
        // 1. Bouw volledige prompt uit request.messages (niet alleen laatste)
        // 2. Gebruik --resume <session_id> als we al een sessie hebben
        // 3. Parse stream-json output voor content + tool_calls
        // 4. Sla session_id op voor volgende call
        // 5. Return ChatResponse met geëxtraheerde content
    }
};
```

**Voordelen:**
- Bouwt voort op bestaande ClaudeCliProvider
- Sessie-persistentie via `--resume` flag
- Stabielere interface dan pipe-based IPC
- Relatief eenvoudig te implementeren

**Nadelen:**
- Nog steeds spawn-per-request, maar met sessie-continuïteit
- Geen echte streaming (wel stream-json parsing)
- Afhankelijk van Claude CLI's sessie-management

**Geschatte complexiteit**: Middel. Incrementele verbetering van bestaande code.

### Optie C: MCP Server Bridge

```
NullClaw ←→ MCP Client ←→ Claude CLI als MCP Server
```

**Concept**: Claude Code ondersteunt het Model Context Protocol (MCP). NullClaw
zou als MCP client kunnen fungeren en Claude CLI als MCP server gebruiken.

**Voordelen:**
- Gestandaardiseerd protocol (JSON-RPC over stdio)
- Bidirectionele communicatie
- Tool support is native in MCP
- Toekomstbestendig

**Nadelen:**
- MCP is primair ontworpen voor tools, niet voor chat completion
- Significante architectuurwijziging vereist
- MCP client implementatie in Zig bestaat nog niet
- Overhead van protocol abstractie

**Geschatte complexiteit**: Zeer hoog. Nieuw subsysteem vereist.

## Aanbevolen Aanpak: Optie B (Gefaseerd)

### Fase 1: Enhanced Claude CLI Provider

Verbeter de bestaande `claude_cli.zig` met:

1. **Volledige conversatie-context**: Stuur alle messages mee, niet alleen het laatste
2. **Sessie-persistentie**: Gebruik `--resume <session-id>` voor context-behoud
3. **Stream-JSON parsing verbeteren**: Extraheer ook tool_calls uit de output
4. **Basis streaming**: Implementeer `stream_chat` door stdout pipe incrementeel te lezen

**Bestanden te wijzigen:**
- `src/providers/claude_cli.zig` — Kernimplementatie uitbreiden
- `src/providers/factory.zig` — Classificatie aanpassen voor subscription variant
- `src/config_types.zig` — Config sectie voor subscription settings

**Nieuwe config:**
```json
{
  "models": {
    "providers": [{
      "name": "claude-cli-subscription",
      "mode": "subscription",
      "model": "claude-opus-4-6",
      "session_persistence": true,
      "max_session_age_minutes": 60
    }]
  }
}
```

### Fase 2: Native Tool Support

Voeg native tool support toe door:

1. **System prompt injection**: NullClaw's tools als instructies in het systeem-prompt
2. **XML tool call parsing**: Al ondersteund via `dispatcher.zig` — werkt out-of-the-box
3. **Tool result terugkoppeling**: Via `--resume` de tool-resultaten terug sturen

Dit werkt omdat het XML-fallback pad (`<tool_call>` tags) al volledig
geïmplementeerd is in `src/agent/dispatcher.zig`.

### Fase 3: Streaming & Optimalisatie

1. **Incrementele stdout reading**: Lees stdout pipe character-voor-character
   i.p.v. `readToEndAlloc`
2. **Stream callback integratie**: Emit `StreamChunk` events per JSON line
3. **Session pool**: Meerdere pre-warmed sessies voor parallelle requests
4. **Health monitoring**: Detecteer en herstart dode sessies

## Architectuurimpact

### Wat NIET verandert:
- `Provider.VTable` interface — volledig compatibel
- `ProviderHolder` — `claude_cli` variant bestaat al
- Agent loop in `agent/root.zig` — werkt met elke provider
- Tool parsing in `dispatcher.zig` — XML fallback werkt
- `ReliableProvider` wrapper — failover naar API bij CLI-problemen

### Wat WEL verandert:
- `claude_cli.zig` — Significant uitbreiden (sessie-state, betere parsing)
- `factory.zig` — Nieuwe `claude_cli_subscription` classificatie
- `config_types.zig` — Subscription-specifieke config velden
- `runtime_bundle.zig` — Subscription provider als primaire of fallback optie

### Binary size impact:
- Geschat +2-4 KB voor sessie-management logica
- Geen nieuwe dependencies
- Ruim binnen de 678 KB target

### Memory impact:
- +~8 KB per actieve sessie (session-id + conversation buffer)
- Ruim binnen de ~1 MB RSS target

## Risico's en Mitigatie

| Risico | Impact | Mitigatie |
|---|---|---|
| Claude CLI rate limiting | Hoog | Fallback naar API provider via `ReliableProvider` |
| ToS schending | Hoog | Documenteer als experimenteel; gebruiker is verantwoordelijk |
| Sessie timeout/crash | Middel | Auto-restart met exponential backoff (zoals `daemon.zig`) |
| CLI output format wijziging | Middel | Versie-check bij init; defensieve parsing |
| Geen token tracking | Laag | Schat tokens op basis van tekst-lengte (al bestaand) |

## Proof of Concept Stappen

1. Test `claude -p "hello" --resume <session-id> --output-format stream-json` handmatig
2. Verifieer dat `--resume` daadwerkelijk conversatie-context behoudt
3. Test of tool_call XML tags in de CLI output verschijnen
4. Meet cold start vs warm sessie latency
5. Test rate limits bij herhaaldelijk gebruik

## Conclusie

Een subscription mode via Claude CLI is **technisch haalbaar** binnen NullClaw's
bestaande architectuur. De vtable-driven opzet maakt het mogelijk om een nieuwe
provider-variant toe te voegen zonder de rest van het systeem te wijzigen.

**Aanbeveling**: Start met Optie B, Fase 1 — een enhanced `ClaudeCliSubscriptionProvider`
die sessie-persistentie toevoegt aan de bestaande CLI provider. Dit levert het
meeste waarde met de minste risico's en complexiteit.

De `ReliableProvider` wrapper biedt een natuurlijk vangnet: als de CLI-subscription
faalt (rate limit, crash, timeout), kan automatisch gefailed worden naar een
API-gebaseerde provider.
