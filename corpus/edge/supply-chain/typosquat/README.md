# Eight dependencies, none of them the package you meant

| what somebody meant to install | what this manifest installs |
| --- | --- |
| `@modelcontextprotocol/server-filesystem` | `@modelcontextprotocal/server-filesystem` |
| `@modelcontextprotocol/server-github` | `@modelcontextprotocol/server-githb` |
| `@modelcontextprotocol/server-slack` | `@modlecontextprotocol/server-slack` |
| `@anthropic-ai/claude-code` | `@anthropic-ai/claude-cod` |
| `@anthropic-ai/sdk` | `@anthropic_ai/sdk` |
| `axios` | `axios-http` |
| `chalk` | `chaIk` |
| `cross-spawn` | `cross-spwan` |

`chaIk` is a capital i. `axios-http` is a real-looking name for a package that is not
axios. The March 2026 incident is the reason this group exists: users who installed one
tool during a three-hour window pulled a trojanized HTTP client along with it, because
the dependency -- not the tool -- was what moved.
