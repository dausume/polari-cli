# Standard deployment profiles

A profile is a saved set of `pol prod` answers (the same `POL_PROD_*` keys as `.generated/prod-answers.env`).
`pol prod guide` offers them at the start — continue from the last run, a profile you saved, or one of these — and
`pol prod apply --profile <name> --yes` applies one unattended. Values may use `${LAN_IP}`, `${PUBLIC_IP}` and
`${HOSTNAME}`, expanded when the profile is used. Your own profiles are saved beside the checkout in
`.polari/prod-profiles/<name>.env` (`pol prod profile save <name>`); they never leave the machine.
