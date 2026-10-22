# Product naming and symbol direction

Status: recommendation, 2026-10-19. The user requested logo concepts and a naming discussion with Claude, Agy, Grok, and Devin. The released preview still uses **DeskBridge**. This document does not select a final public name or authorize changes to bundle identifiers, services, data directories, trust records, or installer upgrade identity.

## Recommendation

**Nearpane · 니어페인** is the strongest surviving candidate from the bounded discussion: a neighboring computer becomes a pane inside the user's workspace. It is specific enough to explain the Mac Space experience, and works for both LAN and an existing Tailscale connection. “Near” describes the experience, rather than making a claim about physical distance or the absence of third-party coordination services.

The main weakness is sound: English listeners may hear “near pain” or “nearplane”; Korean 페인 can evoke 폐인. Keep the English spelling visible alongside the Korean name in concepts. These are product judgment calls, not measured user research results.

| Candidate | Korean | Why it remains | Main drawback |
| --- | --- | --- | --- |
| Nearpane | 니어페인 | Coined, expresses a nearby pane and the central screen experience | Pane/pain and nearplane ambiguity |
| Lanepane | 레인페인 | A private passage between workspaces; an alternative coined direction | Repeated vowel sound, pane/pain ambiguity, weaker first-hearing spelling |
| Span | 스팬 | Very short and easy to pronounce; connection metaphor | Highly generic and overloaded in development vocabulary |

Limited exact-name searches did not reveal a relevant product match for Nearpane or Lanepane. That result does **not** establish domain, repository, package-name, trademark, or other availability. No name has been reserved or published.

## What each advisor actually said

| Advisor | Executed discussion | Result |
| --- | --- | --- |
| Claude 2.1.302 | Initial six-name brainstorm and a cross-critique of actual Claude/Agy outputs and confirmed collisions; both completed with exit 0 and terminal marker | Nearpane first; Paneway alternative |
| Agy 1.4.2 | Initial six-name brainstorm and the same cross-critique; both completed with exit 0 and terminal marker | Initially Sill/Breezeway, then Nearpane after collision evidence; Lanepane alternative |
| Devin CLI 3000.11.92 | First attempt timed out after a login-status message; one retry completed. A subsequent cross-critique of actual Claude/Agy/Devin outputs also completed | Oriel first, Nearpane second. Coordinator later excluded Oriel using first-party evidence |
| Grok 1.0.62 | First attempt printed six candidates, top two, a symbol concept, and the requested terminal marker, but did not exit before the 130-second deadline. One retry produced no answer before termination | Uncounted text favored Alcove/Oriel. Both names have existing Mac-product uses. No completed-process result is claimed |

Claude and Agy independently preferred Nearpane after discussing each other's suggestions. Devin preferred Oriel. This is not a claim of unanimous agreement or four completed advisor runs.

## Confirmed naming conflicts

These are first-party product-name observations, not a trademark assessment. Common-noun names can have many uses beyond this bounded check.

- **DeskBridge:** an existing developer-oriented [remote desktop app](https://apps.apple.com/dk/app/deskbridge/id6766424742), and a separate [remote screens/files/terminal product](https://www.deskbridges.com/), are close to this product's scope.
- **Ferry:** [MAMP's native Mac FTP/SFTP app](https://www.mamp.info/ferry/) overlaps the proposed file-transfer capability.
- **Transom:** an existing [Mac/Windows remote-window streaming project](https://github.com/aydinmrnv/transom) makes this an especially confusing choice.
- **Oriel:** [Domus's open-source Mac window manager](https://domus-apps.com/kr) and [Inveil's native Apple browser](https://inveil.net/) already use the name.
- **Sill:** [an existing open-source social-link app](https://docs.sill.social/) and [Domus's Mac terminal-completion app](https://domus-apps.com/kr) use the name.
- **Sidelight:** an existing [open-source native Mac side-panel app](https://www.getsidelight.app/) has a close audience and visual metaphor.
- **Alcove:** an existing [Mac productivity app](https://alcovetasks.com/) uses the name.
- **Inlet:** an existing [native Mac database app](https://inletdb.com/) uses the name.
- **Breezeway:** an existing [operations software platform](https://www.breezeway.io/) uses the name.

## Logo concept brief

Use a name-independent **paired workspaces** symbol so the product can gain a recognizable icon before a final name is selected.

- Two rounded geometric planes, offset or stepped, with a deliberate negative-space passage between them. A quieter narrow side plane can echo the approved A / Quiet Sidebar interface.
- Deep ink `#14202B`, restrained teal `#2A9D9A`, muted slate blue `#4A6FA5`, and an off-white variant. Prefer flat shapes with a restrained native material treatment at large sizes.
- At 16 px, reduce to two solid high-contrast shapes with a clear gap. Drop tiny pairing dots, interior columns, and decorative lines. The mark must work in monochrome.
- Avoid monitors/laptops, padlocks/shields, OS logos, text inside the icon, network diagrams, and implied performance/security guarantees.
- Explore three compositions: offset panes, sidebar plus open pane, and a stepped bay-window silhouette. Evaluate light/dark backgrounds and Dock, installer, and small-icon contexts.

Any generated image is a concept until selected and checked at real icon sizes. Preserve the existing Mac A design and the application's current trust and upgrade identities while Windows setup is simplified.

## Evidence and limits

Replayable evidence is retained under ignored `.omx/artifacts/naming-20261019/`: fresh CLI preflight probes, exact prompts and SHA-256 hashes, per-invocation version/argv/cwd/timestamps/exit status, separate original stdout/stderr, first-party collision sources, and a machine-readable result. Raw CLI evidence contains local authentication metadata and is excluded from public documentation and user packages.

The advisors received only an inline public synthetic product brief and previous naming suggestions. No source code, production preferences, clipboard, UI, Local Media content, existing private history, or service logs were supplied. Claude/Grok support empty built-in tool allowlists; Devin used a fresh custom permission-deny/import-disabled config. Agy exposes sandbox restrictions but no supported all-tools-off switch; its prompt prohibition is not represented as enforced tool removal. No unavailable model or missing result was substituted.
