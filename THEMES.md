# Themes

Each theme is one folder here. The app finds them at build time (`registry.ts`), so:

- **Add a theme:** add a folder with an `index.ts` whose default export is a `ThemeDefinition` (`types.ts`).
- **Remove a theme:** delete its folder. Nothing else refers to it by name.
- **Pick one at deploy time:** `deploy.ps1 -Theme <folder name>`. It is written to `config.json`; the
  script refuses a name that has no folder. With no theme in `config.json`, `azure-portal` is used, or
  the first theme found if it was deleted (`DEFAULT_THEME` in `registry.ts`).
- **Or in the parameter file (for a CI/CD pipeline):** `portalTheme` in
  `azResources/azuredeploy.parameters.<env>.json`. Bicep writes it to the portal Web App as `PORTAL_THEME`;
  a pipeline can copy it into `config.json` (deploy.ps1 uses `-Theme` instead).
- **Language is separate:** `deploy.ps1 -Language en|da` sets the text (and currency) for every
  theme. A shell shows no hard-coded text of its own: it reads `t.shell.*` from `src/i18n/`.
- **Private themes stay out of the repository.** `.gitignore` ignores every theme folder except
  the public ones it lists (`!src/web-app/src/themes/azure-portal/`), so your own branding theme
  builds and deploys from your clone but is never committed. To publish a theme, add a `!` line.

| Folder | Look | Dark mode |
|---|---|---|
| `azure-portal` | portal.azure.com: blue top bar with a search box, portal menu (docked open on screens 1024 px and wider, collapsible and remembered per browser; a fly-out on narrower ones), breadcrumb, white tiles on grey, Segoe UI | Yes, follows the OS |

## What a theme contains

| File | Purpose |
|---|---|
| `index.ts` | `id` (= folder name), `label`, Fluent theme (light/dark), `palette` (colours the pages draw in code: charts, priorities), `Shell` |
| `Shell.tsx` | The frame around every page: header, navigation, footer. Receives `ShellProps` (`types.ts`). The Ask panel is the app's, not the theme's; a shell may add a search box that calls `ask(question)` to open it. |
| `theme.css` | All styling, scoped to `html.theme-<id>` so it has no effect while another theme is active. It styles the shared page classes (`fo-*`) and its own shell classes. |

The pages (`src/pages/`) use only the shared `fo-*` classes and the palette, never a theme's colours
directly, so a new theme restyles them without code changes.
