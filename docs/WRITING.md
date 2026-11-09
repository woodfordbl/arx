# Writing the arx docs

How to write a page in `docs/`. The rules come from the docs of Cursor,
Vercel and fx, adapted to a small C tool whose readers are engineers and
the agents they run. Follow them for every new page and every edit.

The site renders these files at
[arx-documentation.vercel.app](https://arx-documentation.vercel.app), and
serves each one to agents as markdown at `/docs/<page>.md`. Write every page
so it still makes sense when an agent fetches it on its own.

## The voice

Write like a colleague who knows arx well and respects the reader's time.

- **Talk to the reader.** Use "you" and the present tense. arx is the actor:
  "arx reloads the spec", not "the spec is reloaded".
- **Lead with the answer.** The first sentence of a page or section says
  what the thing is or what the reader will get. Background comes after, if
  at all.
- **Have an opinion.** Name the default and say when to use something else:
  "For most runs, keep `mask`." Say what to avoid and why.
- **Name the mechanism.** "arx checks every harness file with `stat()`
  before each model call" beats "arx reloads quickly". Give exact numbers,
  defaults and units.
- **Head off the misreading.** One short sentence that says what something
  is not saves a support question: "A `before_tool` hook is a guard, not a
  sandbox."
- **Keep it short.** Sentences of 8 to 20 words. Paragraphs of one to three
  sentences. One idea per paragraph.
- **Contractions are fine** ("don't", "isn't", "you'll").

### Words to avoid

| Avoid | Why | Instead |
|---|---|---|
| simply, just, easy, simple, quick | it is not easy for everyone | say the step |
| very, really, powerful, seamless, robust | it says nothing | name the mechanism or the number |
| please, note that, in order to | filler | cut it |
| this page explains, in this section | the heading already says so | start with the content |
| the user | the reader is "you" | you |
| here (as link text) | it does not say where | name the destination |
| significantly, typically, often | weasel words | a real figure, or cut it |

No em dashes and no `--` as punctuation. Use a colon, a comma or two
sentences. Use the Oxford comma. American spelling.

## Page types

Every page is one type and does one job. The type decides how it opens, how
its headings read and how it ends.

| Type | Job | Pages | Headings | Ends with |
|---|---|---|---|---|
| Tutorial | take the reader from nothing to a result | Getting started, Plugin quickstart | imperatives: "Write a tool" | Next steps |
| Concept | explain how a part works and why | How arx works, Plugin concepts | nouns: "The turn loop" | Next steps or Related |
| Guide | solve one task the reader already has | Self-improving runs, each plugin kind | imperatives or nouns | Related |
| Reference | list every option, exactly | agent.yaml, Command line, Plugin reference | the names themselves: "`limits`" | nothing, or Related |
| Project | record decisions and plans | Architecture, Roadmap, Planned changes | nouns | nothing |

### How a page opens

The H1 is a noun for a concept or reference page ("Hooks", "Command line"),
or the outcome for a tutorial ("Getting started"). Then:

1. **One sentence that defines the subject**, in the shape "X does Y":
   "A hook is an executable that arx runs at a fixed point in the turn
   loop." The site uses this sentence as the page description, so it must
   stand alone.
2. **One or two sentences on why or when** you would use it.
3. For a tutorial: what you'll have at the end, how long it takes, and what
   you need.

Never open with history, a list of contents, or "This page".

### Headings

- Sentence case for every heading: "Set up a provider", not "Set Up a
  Provider".
- Specific enough to predict the section: "Bad edits are safe", not "Notes".
  No "Overview", "More", "Misc" or "Details".
- Troubleshooting headings are the literal error or symptom:
  "`arx: command not found`".
- Other pages link to headings by their anchor. When you rename a heading,
  search `docs/` and `README.md` for the old anchor and fix every link.

### How a page ends

- **Tutorials and concepts** end with `## Next steps`: two to four bullets,
  each a link and what the reader will do there.

  ```markdown
  ## Next steps

  - [How arx works](concepts.md): the turn loop, hot reload and sessions.
  - [Plugins](plugins.md): every way to extend arx.
  ```

- **Guides** end with `## Related`, the same shape.
- **Reference and project pages** stop when the content stops. No summary,
  no recap.

## Structure inside a page

### Steps

- A procedure of three or more actions is a numbered list, or numbered H3s
  in a tutorial ("### 1. Build arx").
- One action per step, in the imperative: "Run `arx setup`."
- Put a condition before the step it applies to: "If `~/.local/bin` is not
  on your `PATH`, add it:".
- Put a warning before the step it affects, never after.
- End a step with its visible result when there is one: the output in a
  `text` block, or "arx prints the tools as the model sees them."

### Lists and tables

- Use a table when items have two or more attributes. A table of choices
  gets a "Use it when" column, so it guides the decision as well as listing.
- Use bullets for three or more parallel items. Introduce the list with a
  colon.
- A bullet that starts with a term uses `**Term**: description.` (bold
  term, colon outside the bold).
- Bold is for those terms and for UI labels. Never for emphasis in a
  sentence.

### Callouts

Use GitHub alerts. They render on GitHub and on the site:

```markdown
> [!NOTE]
> Observers start once, when the session starts. A reload does not restart them.
```

| Alert | For |
|---|---|
| `[!NOTE]` | a fact that is easy to miss: a default, a version gate, a scope limit |
| `[!TIP]` | a better way to do the step, for readers who want it |
| `[!WARNING]` | something that loses work, spends money or weakens a guard |

At most two callouts per page. If everything is a note, nothing is.

### Code

- Every fence has a language: `sh`, `yaml`, `json`, `c`, `python`, or
  `text` for output and diagrams.
- Every command must run as shown. Run a tutorial's blocks in order in an
  empty folder before you merge a change to it.
- In a block of several commands, put a short `#` comment after each command
  that says what it does, aligned in one column. Keep each line under 80
  characters, so the block does not scroll on the site.
- Show the output after a command when it proves the step worked, in its own
  `text` block.
- When a block is a file, put its path on the first line as a comment
  (`# agent.yaml`) or say it in the sentence before.
- Use realistic values: real model names, real paths, real numbers. For a
  value the reader supplies, write it in capitals in the CLI's own style
  (`--spec PATH`), as `arx help` does.
- Keep blocks under about 25 lines. Explain every block in a sentence before
  it.

### Inline code

Use backticks for every command, flag, key, path, file name, environment
variable, event type, hook point and exit code: `arx check`, `--cap`,
`limits.max_turns`, `~/.config/arx/`, `ARX_CONFIG_DIR`, `before_tool`.
Keys are written as text: Ctrl-C, Ctrl-D.

### Links

- Link to other pages with relative paths to the `.md` file:
  `[Hooks](plugins/hooks.md#bands)`. The site turns them into routes, and the
  markdown copies into absolute URLs.
- Link text names the destination: "see [Hooks](plugins/hooks.md)", never
  "see [here](plugins/hooks.md)".
- Link a term the first time a page uses it, not every time.
- Say "on this page" or link the heading instead of "above" and "below". An
  agent may read one section without the rest.

## Status: today and planned

Document what arx does today. Something designed but not built goes on
[Planned changes](plugins/planned.md) or the [Roadmap](roadmap.md), or is
marked inline with **Planned:** at the start of its sentence. Never describe
planned behavior in the present tense.

## Names

- **arx** is always lowercase, also at the start of a sentence.
- One name per concept, everywhere: spec, spec folder, harness, layer, hook
  point, kit, active list, cap, limit, session. They are defined in
  [How arx works](concepts.md) and [Plugin concepts](plugins/concepts.md).
  Do not swap in synonyms ("config file" for spec, "plugin dir" for layer).
- Model providers by their own names: Vercel AI Gateway, OpenRouter, OpenAI,
  Ollama.

## Format of the file

- Wrap prose at 80 columns, like the C sources. Tables and links may run
  longer.
- One H1, the page title, on the first line. Then the defining sentence as
  the first paragraph.
- No HTML, except where markdown cannot do it.
- Add a new page to `src/lib/nav.mjs` in arx-docs, with a one-line blurb.
  The blurb is the page's entry in `/llms.txt`.

## Checklist

Before you open a pull request, check the page against this list:

- [ ] The first sentence defines the subject and stands alone.
- [ ] Every heading is sentence case and says what its section holds.
- [ ] No word from "Words to avoid", no em dash.
- [ ] Every command runs as shown, and every fence has a language.
- [ ] Every link resolves, including anchors on other pages.
- [ ] Nothing planned is written as if it works today.
- [ ] Tutorials and concepts end with Next steps; guides with Related.
