# Product

## Register

brand

## Users

Experienced Ada and GNAT developers building PostgreSQL clients, protocol
servers, test doubles, and database-adjacent infrastructure are the primary
audience. Systems programmers evaluating Flyology should be able to understand
the protocol coverage, streaming model, authentication boundaries, and path to
a working client or server without reading the entire repository.

## Product Purpose

Flyology Postgres presents a native Ada implementation of the PostgreSQL
frontend/backend protocol over Flyology I/O. The public site should help a
visitor understand the client and server surfaces, reach a working first
connection, choose the correct bounded streaming API, and evaluate the current
security and transport boundaries responsibly.

## Brand Personality

Precise, mechanical, and quietly curious. The voice is modest and factual,
with the confidence of a well-annotated protocol diagram. It is visibly part of
Flyology, with PostgreSQL wire framing and state transitions providing the
project-specific visual and narrative material.

## Anti-references

Do not use neon-terminal developer-tool cliches, database-cylinder clip art, a
generic startup card wall, or faux-Victorian ornament. Avoid inflated
compatibility claims, glassmorphism, decorative complexity, and any treatment
that hides protocol state or current security boundaries.

## Design Principles

- Show the protocol flow before describing it at length.
- Keep bounded streaming and explicit state transitions visible.
- Pair every capability with its transport, authentication, or scheduling boundary.
- Keep ordinary Ada syntax at the center of the story.
- Make the shortest path to a real PostgreSQL connection obvious.

## Accessibility & Inclusion

Target WCAG 2.2 AA. Preserve full keyboard navigation, visible focus states,
semantic headings, color-independent meaning, readable code at narrow widths,
and a complete reduced-motion experience.
