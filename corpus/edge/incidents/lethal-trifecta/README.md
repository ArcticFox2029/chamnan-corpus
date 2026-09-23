# Three things, none of which is a vulnerability

1. **Privileged access** — `config/production.env`, readable by an agent with service-role
   credentials.
2. **Untrusted input** — `issues/`, written by whoever opened the ticket.
3. **An output channel** — a comment, a pull request, a reply.

Remove any one and nothing happens. The Supabase demonstration had a Cursor agent with
service-role access reading support tickets that contained SQL; the GitHub MCP one needed
only "take a look at the issues" to leak the names of private repositories.

Both were demonstrated by researchers. No customer data leak has been reported from
either, and saying so is part of citing them honestly.

https://simonwillison.net/2025/Jul/6/supabase-mcp-lethal-trifecta/
https://www.docker.com/blog/mcp-horror-stories-github-prompt-injection/
