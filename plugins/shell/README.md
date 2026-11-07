# shell

The `bash` and `edit` tools. Their code is in the arx binary (`arx tool
bash` and `arx tool edit`), so they are fast and need no other programs;
this plugin only connects them. Each tool's schema is in `tools/<name>.json`,
so arx loads them without starting a process.

`arx setup` installs this plugin for you, from the copy that comes with arx.
To run the tools somewhere else, such as in a sandbox, install a plugin with
its own `bash` and `edit` in a layer above this one, for example in
`./plugins/`: the first tool with a name wins.

Settings: `tools.bash.timeout` and `tools.edit.timeout` (default 120s), and
`enabled: false` to turn one off.
