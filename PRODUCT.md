# Shoestring

A local supervisor for people running agent work through a CLI. The web UI
has six destinations: Usage, Teams, Agents, Sessions, Lessons and Settings.
Users save teams that assign an agent (model, limits, sandbox permissions) to
each role, inspect reported subscription limits, watch coordinator sessions,
answer workers' asks and decide on lessons. Work submission, plan approval,
grants, integration and diagnostics belong to the CLI (`shoestring do`,
`shoestring chat`). Chat itself lives in the terminal chat screen; raw run and
terminal output pages are diagnostic surfaces outside the main navigation.

Provider/account allowance is shared, never multiplied by the number of agents.
Unknown and stale readings stay explicit. No inference call is authorized by
saving configuration. A saved model identifier is user configuration, not proof
of provider entitlement. Immutable revisions allow stable CLI lookup; execution
must explicitly bind a snapshot in its own contract.

The accepted HTML concept is plans/mockups/configuration-and-usage.html.
Implementation uses its Focus top navigation, quiet green/neutral palette,
system typography and compact observed-window bars. Desktop and mobile web;
Firefox or Brave. No external fonts or image assets are required.
