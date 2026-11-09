# Contributing

Thanks for your interest in improving the Azure AI FinOps Portal. This is a
self-hosted Azure solution (Bicep + PowerShell Function App + a static portal),
so most contributions are bug fixes, doc improvements, or small features.

## AI-assisted development

This project was built with [Claude Code](https://claude.com/claude-code) (see the README).
AI-assisted contributions are welcome under the same rules as any other: you are responsible for
the change, it comes with tests, and the offline tests pass.

## Before you start

- For anything non-trivial, **open an issue first** to discuss the approach.
- For security issues, **do not** open a public issue — see [SECURITY.md](SECURITY.md).

## Golden rule: never commit real tenant data

This repo is public. Do **not** commit subscription IDs, tenant IDs, object IDs,
real resource/user names, emails, public IPs, AI provider keys, or secrets.

- Put real values only in `azResources/*.local.json` or `*.tst.json` — these are
  git-ignored. `azuredeploy.parameters.dev.json` is the public template and holds placeholders only;
  `azuredeploy.parameters.prd.json` is committed too, with placeholder values only.
- Company branding goes in its own theme folder, which is git-ignored unless `.gitignore` lists it.
- `Setup/_setup-context.json` is generated locally and git-ignored; keep it that way.
- If you add screenshots, **redact** org name, identity names, GUIDs, owners,
  emails, and cost figures before committing.
- Use the placeholder/`Contoso` conventions already in the docs and example files.

## Architectural rule: calculate deterministically, explain from evidence

- **The AI never produces a number.** All arithmetic over cost data lives in the deterministic
  modules (`CostAnalysis.psm1`, `CostEvidence.psm1`, `SavingsFinder.psm1`, `Brief.psm1`).
  **Do not** add code paths that ask the model to sum, diff, estimate or otherwise produce cost
  figures, and keep prompts telling it not to write amounts — the UI renders them from data.
- **The AI never explains without evidence.** A new AI feature gathers its facts in code first,
  sends them numbered, requires the model to cite them (or reference payload items by id), and
  validates the citations. No evidence → no call. Never ask the model to "guess the likely cause".
- **No rewording.** Don't send text the app already has to the model just to rephrase it.
- **Everything works without AI**, and every call goes through `Invoke-AiCompletion` or
  `Invoke-AiAgent` so it is counted against the daily limit. Run `Test-NarrativeGrounding` on any
  new AI prose.
- **No names to the model.** Agent payloads and tool results pseudonymise owners, subscription
  names and GUIDs; agent tools stay read-only.

## Provider neutrality

The product is BYOK and provider-agnostic. New features call `Invoke-AiCompletion`; they
must not hard-code a vendor. Provider-specific code belongs only in the adapter functions
(`Invoke-OpenAiCompatible`, `Invoke-AnthropicMessages`).

## Development

- **Infrastructure:** `azResources/main.bicep` (+ `azuredeploy.parameters.*.json`).
  Validate with `az bicep build -f azResources/main.bicep`.
- **API:** PowerShell 7.6 Functions under `src/function-app/`. HTTP triggers are
  `authLevel: anonymous` (EasyAuth fronts auth); timer triggers populate the tables.
  Shared code is in `src/function-app/Modules/` (auto-imported) and `profile.ps1`.
- **Portal:** Vite + React + Fluent UI v9 + Recharts under `src/web-app/`. The look comes
  from a theme folder (`src/web-app/src/themes/`, see [THEMES.md](THEMES.md)); pages use only the shared
  `fo-*` classes and the theme palette. `npm install` then `npm run dev` to run locally; `npm run build`
  outputs static files to `dist/`. The API base URL is loaded at runtime from
  `config.json` (never baked at build time) so one build is tenant-agnostic.
- **Tests:** `pwsh ./Tests/Invoke-OfflineTests.ps1` — a PowerShell parse check, the
  `Tests/*.Tests.ps1` files (stubs in `Tests/TestKit.ps1`: no Azure, no AI provider) and
  `node --test` for the portal server. Add a test with every behaviour change.
- **Deploy to test your change:** `./deploy.ps1 -ResourceGroupName <rg> -SubscriptionId <id> -CodeOnly`
  (requires `pwsh` and Node.js 22.12+). It runs the offline tests first and stops if they fail.
  `deploy.ps1` is the supported deploy path.
