## Language

- **Rule:** All content committed to the repository (docs, notes, code comments, commit messages, scripts) must be in **English**.
- **Context:** Project owner preference (2026-06-10). Chat may be in Polish, but repository artifacts stay in English.
- **Updated:** 2026-06-10

## Naming

- **Rule:** The desktop-image component is named **`selkies`** everywhere — builder `linux-debian/debian_qcow2-cloud-init-selkies.sh`, payload dir `linux-debian/selkies/`, services `selkies.service` / `start-selkies.sh`. `selkin` is NOT a valid name for the component/dir/builder and must never appear in repo artifacts.
- **Context:** Earlier notes used `selkin` by mistake; the codebase always used `selkies`. Reconciled 2026-06-15 (user: "selkies wszędzie, to poprawna nazwa"). The default Selkies basic-auth credentials (builder `SELKIES_USER`/`SELKIES_PASSWORD`) were aligned the same day to `selkies`/`321selkies` (previously `selkin`/`321selkin`), so `selkin` no longer appears as a name or a default value.
- **Updated:** 2026-06-15
