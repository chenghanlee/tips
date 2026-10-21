# Design docs

Design facts: the technical truths an agent must know before changing the system.
Status and plans live on [GitHub Project 15](https://github.com/users/chenghanlee/projects/15).
Product purpose and principles live in [PRODUCT.md](../../PRODUCT.md). Each design doc
lives in this folder and grows one story at a time. `scripts/check_docs.py` fails when a
link here points at a missing heading or a design-doc section has no row here.

| File | Owns |
|---|---|
| [data-model.md](data-model.md) | Tables, indexes, migration rules |
| [content.md](content.md) | The `Tips.Content` context: functions, URLs, validation, error text |
| [decisions.md](decisions.md) | Dated decisions with reasons |

## Read when

| Read when | Sections |
|---|---|
| Any migration or schema change | [Rules](data-model.md#rules), [Posts](data-model.md#posts) |
| Any change in `Tips.Content` or a page that calls it | [Functions](content.md#functions), [URLs](content.md#urls) |
| Any form, validation or error text | [Validation and error text](content.md#validation-and-error-text) |
| Choosing a front-end or test approach, or a library | [2026-10-21](decisions.md#2026-10-21) |
