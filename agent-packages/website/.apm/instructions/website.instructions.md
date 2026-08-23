---
description: Apply Flyology Postgres's documentation rules within the website tree.
applyTo: "website/**"
---

# Flyology Postgres website documentation guide

## Scope

Apply the technical writing style to hand-written documentation in `guide/**`
and `architecture/**`. Apply the journal register below to `journal/**`. These
rules do not apply to the home page or generated API reference.

## Technical writing style

Use the useful parts of ASD-STE100 as a house style. Do not claim that the
documentation complies with ASD-STE100.

- Use the project vocabulary in the root `AGENTS.md`. Use one term for one
  concept. Do not add synonyms only for variety.
- Define an unfamiliar term before its first use. Keep Flyology Postgres
  identifiers, Ada terms, protocol terms, and PostgreSQL terms exact.
- Put one main idea or one instruction in each sentence. Use a list when three
  or more parallel facts would make a long sentence.
- Keep closely related cause, contrast, sequence, and consequence in the same
  paragraph. Do not split one connected explanation into abrupt statements
  only to meet a sentence-length target.
- Prefer sentences of 25 words or fewer. Prefer 20 words or fewer for an
  instruction. Treat these limits as review signals, not mechanical rules.
- Use active voice when the actor matters. Name the actor instead of using an
  unclear `it`, `this`, or `they`.
- Preserve modal meaning. Use `must` for a requirement, `can` for capability,
  and `may` for possibility. Rewrite ambiguous capability or possibility.
- Use present tense for current behavior and the imperative for instructions.
  Put a condition before the action when the condition controls it.
- Put a prerequisite or safety condition before its action. Natural forms such
  as "use X when Y" are acceptable when the condition does not gate safety,
  validity, or ownership.
- Use direct, sentence-case headings. State the subject or action.
- Prefer concrete verbs. Avoid stacked modifiers, nominalizations, rhetorical
  questions, idioms, metaphors, personification, filler, and promotional prose.
- Keep limits next to the capability that they qualify. Do not remove a
  condition, ownership rule, exception, or timing fact to shorten the prose.
- Use short paragraphs. Start a new paragraph when the subject or task changes.

The result must read like normal software documentation. Do not imitate an
aircraft maintenance manual, force a restricted dictionary, repeat nouns when
the reference is clear, or split connected reasoning into unnatural fragments.

Examples and walkthroughs can use a slightly more human cadence. Their setup
may explain why a realistic case matters, and their explanation may vary
sentence length to connect cause and effect. Use this allowance with restraint.
Commands, contracts, warnings, and limits still use the tighter style. Do not
add a fictional user, dramatic scenario, metaphor, or extra personality when
it does not improve understanding.

Review an example as a paragraph, not only as sentence-length scores. If three
or more short sentences have the same subject, combine or connect them when
this improves the sequence. Retain a short sentence when it states a warning,
result, or important boundary.

Before finishing, check term consistency, sentence length, HTML syntax, local
links, and code examples. Sentence-length scripts are triage tools, not gates.
Review the meaning and cadence of every flagged sentence before changing it.

## API links

On each Guide, Architecture, or Journal page, link the first visible
explanatory mention of a public Flyology Postgres API entity to its generated
GNATdoc entry. API entities include packages, generic packages, subprograms,
types, objects, exceptions, enumeration literals, and other declarations.

- Follow document reading order. The first mention can occur in a hero,
  callout, paragraph, list, table, or figure caption.
- Use `<a href="..."><code>Entity_Name</code></a>` for an identifier in prose.
- Link a package name to its GNATdoc unit page. Link a declaration to its exact
  entity anchor when that anchor exists.
- For an overloaded subprogram, link the declaration that matches the
  described operation. If prose refers to the overload family, link the package
  page.
- If an identifier first appears in a code block, code comment, or SVG text,
  link it in the nearest explanatory prose or caption. Do not put an HTML link
  inside a code block or SVG source label only to satisfy this rule.
- Do not guess a generated filename or anchor. Resolve it through generated
  GNATdoc output or its search index, then verify the target and fragment.
- Link only the first explanatory mention of an entity on a page. Repeat a link
  only when the spelling refers to another entity or a long page needs a
  deliberate navigation aid.
- Do not link Ada constructs, PostgreSQL commands or messages, OS interfaces,
  environment variables, shell commands, scripts, or external APIs to
  Flyology Postgres GNATdoc.
- Use `api/` for the protocol, transport, client, server, authentication, and
  replication reference. Use `sql-api/` for the nested SQL parser, owned AST,
  visitor, shallow-view, and catalog reference.
- `scripts/docs.sh` enables GNATdoc warnings for both references. Generated SQL
  declarations currently produce expected undocumented-entity warnings. Keep
  those warnings visible, and review their change when a generator or public
  SQL surface changes.
- When no generated entry exists for a public Flyology Postgres identifier,
  record a review finding. Extend the appropriate generated reference when the
  entity is part of the documented public surface. Do not link to an unrelated
  package.

## Journal register

Journal entries use the same exact vocabulary, concrete verbs, factual limits,
and restrained claims. They can use a more personal voice.

- First person is acceptable when it identifies an observation, decision, or
  correction made by the author or project team.
- Use `we` for the project or team. Use `I` only when a named author records a
  direct observation or decision.
- Use past tense for dated work and observations. Use present tense for a
  current finding, implementation fact, or limit.
- Vary sentence length enough to keep a natural narrative. Do not apply the
  20-word and 25-word targets mechanically.
- Give the reason for an investigation and explain what changed in the team's
  understanding. Keep the evidence and its limits close to that account.
- A small amount of warmth or dry humor is acceptable. Do not use a conceit,
  extended metaphor, fictional scene, or dramatic claim for a technical point.
- Prefer a candid correction to defensive wording. Preserve the source
  revision, environment, method, result, and limits needed to assess a claim.

## Review roles

For a broad rewrite of three or more pages, use three separate read-only review
roles on the settled draft. Reviewers report findings and do not edit the same
checkout concurrently. Run a technical review for each changed capability,
limit, ownership, timing, or lifecycle claim.

Use one separate subagent for each role when multi-agent support is available.
Do not edit reviewed files while reviewers work. Each finding identifies its
severity, exact location, relevant wording, violated rule, and correction. A
technical finding also names the implementation, script, contract, or
invariant that supports it.

### Editorial reviewer

- Review headings, paragraph order, cadence, transitions, and cognitive load.
- Identify mechanical splitting, repeated openings, vague headings, and prose
  that needs list structure.
- Give examples enough connective prose to explain why one step follows
  another. Keep the tone restrained.
- Review the journal for a candid, personable voice without a decorative story.

### Technical reviewer

- Compare the rewrite with the earlier text, implementation, runners, README,
  and root `AGENTS.md`.
- Check the first explanatory API mention against exact generated GNATdoc.
- Check each condition, ownership rule, exception, timing fact, lifecycle
  boundary, concurrency limit, and experimental qualification.
- Check that every `must`, `can`, and `may` retains its intended meaning.
- Report any fact that became weaker, broader, or ambiguous. Treat executable
  code and maintained scripts as stronger evidence than earlier prose.

### ASD-STE100-inspired controlled-language reviewer

- Apply this file without claiming ASD-STE100 compliance.
- Check one term per concept, active voice, clear actors and references,
  condition-before-action order, direct headings, and concrete verbs.
- Flag long or complex sentences, excessive splitting, and unnatural repeated
  nouns.
- Apply tighter targets to instructions and warnings, not mechanically to
  examples and journal narrative.

The editing agent reconciles all three reviews. Technical fidelity wins when a
style suggestion would remove meaning. Resolve technical findings first, then
editorial and controlled-language findings. Run a targeted technical review on
factual passages changed during reconciliation. Review metadata, navigation,
callouts, captions, SVG text, code comments, and redirects with body prose.

If separate reviewers are unavailable, perform and label the three reviews in
sequence. Do not collapse them into one generic prose pass.
