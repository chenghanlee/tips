# Content context

`Tips.Content` owns user-created content: posts now, replies and media later. The web
layer calls only the functions below. Schema: `Tips.Content.Post`, table `posts`
([Posts](data-model.md#posts)).

## Functions

| Function | Returns | Notes |
|---|---|---|
| `create_post(attrs)` | `{:ok, post}` or `{:error, changeset}` | Sets `uid` and `slug` |
| `change_post(post, attrs \\ %{})` | changeset | For forms |
| `get_post!(uid)` | post | Raises `Ecto.NoResultsError`, which renders 404 |

`uid` comes from the `nanoid` library, 12 characters. `slug` comes from the `slugify`
library applied to the title, cut to 80 characters at a whole word.

## Validation and error text

The changeset checks required fields and lengths. HTML `required`, `minlength` and
`maxlength` give instant feedback in the browser. The server is the authority.

Error text follows the GOV.UK Design System pattern: one short sentence that says what
to do.

| Field | Condition | Text |
|---|---|---|
| title | empty | Enter a title |
| title | under 3 characters | Title must be 3 characters or more |
| title | over 300 characters | Title must be 300 characters or fewer |
| body | empty | Enter a body |
| body | under 3 characters | Body must be 3 characters or more |
| body | over 20,000 characters | Body must be 20,000 characters or fewer |

Show the text below the field, in red, linked to the field for screen readers. Keep the
typed text. Save nothing when any field fails.

## URLs

| URL | Page |
|---|---|
| `/tips/new` | the post form |
| `/tips/:uid/:slug` | the post |

- A wrong slug in the URL gets a 301 redirect to the stored slug.
- An unknown `uid` gets a 404.
- The Phoenix home page stays until a story replaces it.
