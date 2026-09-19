# Standard deployment profiles

A profile is a saved set of `pol prod` answers (the same `POL_PROD_*` keys as `.generated/prod-answers.env`).
`pol prod guide` offers them at the start — continue from the last run, a profile you saved, or one of these — and
`pol prod apply --profile <name> --yes` applies one unattended. Values may use `${LAN_IP}`, `${PUBLIC_IP}` and
`${HOSTNAME}`, expanded when the profile is used. Your own profiles are saved beside the checkout in
`.polari/prod-profiles/<name>.env` (`pol prod profile save <name>`); they never leave the machine.

| profile | what it is for |
|---|---|
| `local-instance` | one machine, for yourself |
| `public-server` | a server with logins, on a domain |
| `demo-server` | the same, with the demonstration notice |
| `distribution-server` | a distribution point: no logins, the published installers handed out |
| **`pipeline-device`** | **the core that holds the BUILD PIPELINE's settings (ci-8).** Its `POL_PROD_MODULES` ends in `,cicd`, so the `cicd` module is admitted by construction — that is what "always enabled with the pipeline" means. `pol jenkins doctor` checks it live and names this profile as the fix when a core answers without `/api/cicd`. |
