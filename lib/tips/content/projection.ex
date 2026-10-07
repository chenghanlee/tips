defmodule Tips.Content.Projection do
  @moduledoc """
  Narrow return shapes for tips, reviews and media read by the web layer.

  Content reads load current rows, then call one of these functions before
  returning anything. Each function asks `Tips.Content.Visibility` first and
  builds its output from an explicit field list. Raw schemas, preloaded
  associations, report data, Stream uids and playback tokens never pass
  through. The only storage reference returned is a readable image's R2 object
  key; see `t:media_item/0`.

  ## Assumptions

  These are pure functions over values the caller already loaded:

    * Rows are current, loaded by the same read. An old search hit, cached
      struct or earlier page is not authorization; reload before projecting.
    * A scope that reaches an author or moderator branch was freshly admitted
      (see "Admission contract" in `Tips.Accounts`). Nothing here verifies a
      session or grants access.
    * `t:capabilities/0` values are display hints for Edit/Delete/Vote/Report
      controls. Every operation rechecks its own locked eligibility.

  ## Hydration

  `t:hydration/0` is a server-only map of display data the caller loaded
  alongside the row. Each function reads only the keys it documents and copies
  selected fields from them; it never merges the map into its output. A missing
  required key raises `KeyError`, and an author or parent that does not match
  the row raises `ArgumentError`, rather than rendering a lookup that did not
  happen. Consumers may skip hydration an unavailable row does not read.

  ## Unavailable tips

  Deleted tips become `Deleted tip` / `deleted-tip` for everyone. Hidden tips
  become `Removed tip` / `removed-tip` for readers who are not the author or a
  moderator. Placeholders keep only the id, so old links still resolve, and
  carry no title, text, setup, attribution, attachments, counts or dates.
  Reviews under an unavailable tip keep their own visibility and see the parent
  only through the same placeholder.
  """

  alias Tips.Accounts
  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.Media.Asset
  alias Tips.Content.{Notification, Review, Tip, Visibility}

  @deleted_title "Deleted tip"
  @removed_title "Removed tip"

  @typedoc """
  A tip's title, neutral slug and state. Placeholders use this shape, and so do
  page metadata, redirects and parent links from reviews, profiles and inboxes.
  """
  @type tip_link :: %{
          state: Visibility.decision(),
          id: pos_integer(),
          title: String.t(),
          slug: String.t()
        }

  @typedoc "An unavailable tip. `state` is `:deleted` or `:removed`."
  @type placeholder :: %{
          state: :deleted | :removed,
          id: pos_integer(),
          title: String.t(),
          slug: String.t()
        }

  @typedoc "A curated label. `id` is the filter value."
  @type label :: %{id: String.t(), label: String.t()}

  @typedoc "A reported model. `id` is `nil` for free text, which has no filter link."
  @type model :: %{id: String.t() | nil, label: String.t()}

  @typedoc "Public attribution. Deleted accounts render as `[deleted]`."
  @type author :: %{handle: String.t()} | :deleted_account

  @typedoc "The viewer's stored vote: Helpful (`1`), Not helpful (`-1`) or none."
  @type vote :: -1 | 1 | nil

  @typedoc """
  Whether each action may execute now for this viewer. These are display
  hints; every operation rechecks its own eligibility.

  `false` is not an instruction to hide a sign-in entry point. An anonymous
  (`nil`) scope gets all `false`, yet pages still render the signed-out
  Helpful/Not helpful/Report variants that lead to sign-in.
  """
  @type capabilities :: %{vote: boolean(), edit: boolean(), delete: boolean(), report: boolean()}

  @typedoc "Tip capabilities, plus whether the viewer may write a new review."
  @type tip_capabilities :: %{
          vote: boolean(),
          edit: boolean(),
          delete: boolean(),
          report: boolean(),
          review: boolean()
        }

  @typedoc """
  A browse or search row. Text only, without media.

  `removed` is `true` when moderators hid a tip that this viewer may still read,
  so the page can show the generic removal notice. It never carries a reason.
  """
  @type summary ::
          placeholder()
          | %{
              state: :visible,
              id: pos_integer(),
              title: String.t(),
              slug: String.t(),
              removed: boolean(),
              tag: label(),
              model: model() | nil,
              environment: label() | nil,
              author: author(),
              created_at: DateTime.t(),
              score: integer(),
              review_count: non_neg_integer(),
              viewer_vote: vote(),
              capabilities: capabilities()
            }

  @typedoc "Tip page context: the summary fields plus text, counts and media."
  @type tip_detail ::
          placeholder()
          | %{
              state: :visible,
              id: pos_integer(),
              title: String.t(),
              slug: String.t(),
              removed: boolean(),
              body: String.t(),
              prompt: String.t() | nil,
              output: String.t() | nil,
              tag: label(),
              model: model() | nil,
              environment: label() | nil,
              author: author(),
              created_at: DateTime.t(),
              edited_at: DateTime.t() | nil,
              score: integer(),
              up_count: non_neg_integer(),
              down_count: non_neg_integer(),
              review_count: non_neg_integer(),
              latest_review_at: DateTime.t() | nil,
              has_earlier_reviews: boolean(),
              viewer_vote: vote(),
              capabilities: tip_capabilities(),
              media: [media_item()]
            }

  @typedoc """
  A readable review.

  `tip` is the parent seen through the same masking as `metadata/2`.
  `by_tip_author` is `true` only when that parent is visible to this viewer and
  the reviewer wrote it; it is `false` under a placeholder.
  """
  @type visible_review :: %{
          state: :visible,
          id: pos_integer(),
          tip: tip_link(),
          removed: boolean(),
          body: String.t(),
          prompt: String.t() | nil,
          output: String.t() | nil,
          model: model() | nil,
          environment: label() | nil,
          author: author(),
          by_tip_author: boolean(),
          created_at: DateTime.t(),
          edited_at: DateTime.t() | nil,
          score: integer(),
          up_count: non_neg_integer(),
          down_count: non_neg_integer(),
          viewer_vote: vote(),
          capabilities: capabilities(),
          media: [media_item()]
        }

  @typedoc "A review, or only its id, state and masked parent when unavailable."
  @type review_view ::
          visible_review()
          | %{state: :deleted | :removed, id: pos_integer(), tip: tip_link()}

  @typedoc """
  A selected-review destination (`/reviews/:id`) with its tip context.

    * `{:visible, review}` for an authorized review of this tip.
    * `:deleted` for a review of this tip its author deleted: "Review deleted by author".
    * `:removed` for a review of this tip hidden from this viewer: "Review removed by moderators".
    * `:unavailable` for `nil` or another tip's review: "Review unavailable".
      `/reviews/:id` derives the tip from the review, so a missing review is
      not found before projection.
  """
  @type selected_review :: %{
          tip: tip_detail(),
          review: {:visible, visible_review()} | :deleted | :removed | :unavailable
        }

  @typedoc """
  The viewer's own review for the tip page header link, including one hidden by
  moderators. Its capabilities match those on the full review projection.
  """
  @type own_review :: %{id: pos_integer(), removed: boolean(), capabilities: capabilities()}

  @typedoc """
  An attachment on a readable tip or review, in position order.

  Images carry their R2 `object_key`; the image delivery consumer turns it into
  a URL under the configured media host. Videos carry stable app routes that
  authorize each request and redirect to a short-lived signed Stream URL. No
  Stream uid or playback token appears here.
  """
  @type media_item ::
          %{
            kind: :image,
            id: pos_integer(),
            position: 0..9,
            description: String.t() | nil,
            animated: boolean(),
            object_key: String.t()
          }
          | %{
              kind: :video,
              id: pos_integer(),
              position: 0..9,
              duration_s: float(),
              watch_path: String.t(),
              thumbnail_path: String.t()
            }

  @typedoc """
  Where a search match excerpt came from. Search returns this with the excerpt
  rather than making the frontend guess. For a review, render `:body` as
  "Review", `:prompt` as "Prompt", `:result` as "Result" and `:setup` as
  "Reviewer setup". A setup excerpt is labelled metadata, not a quotation.
  """
  @type excerpt_source :: :body | :prompt | :result | :setup

  @typedoc """
  A source-labelled match excerpt. `excerpt/4` builds it from a current review
  row visible to this viewer; the search consumer then bounds its text.
  """
  @type excerpt :: %{source: excerpt_source(), text: String.t()}

  @typedoc ~S(Cached curated labels by id, e.g. `%{tags: %{"other" => "Other technique"}}`.)
  @type labels :: %{
          tags: %{String.t() => String.t()},
          models: %{String.t() => String.t()},
          environments: %{String.t() => String.t()}
        }

  @typedoc """
  Server-only display data loaded with the row. See each function for the keys
  it requires.

    * `:author` - the current `users` row of the content's author.
    * `:labels` - see `t:labels/0`.
    * `:viewer_vote` - the scope's stored vote on this row; `nil` when anonymous.
    * `:media` - current `media` rows for this row; `media/3` filters them.
    * `:own_review` - the scope's undeleted review of this tip, or `nil`. Any
      other row raises `ArgumentError`.
    * `:latest_review_at` - `max(created_at)` of this tip's live reviews.
    * `:has_earlier_reviews` - whether a review readable by this viewer predates `edited_at`.
    * `:parent` - the review's current parent tip row.
  """
  @type hydration :: %{
          optional(:author) => User.t(),
          optional(:labels) => labels(),
          optional(:viewer_vote) => vote(),
          optional(:media) => [asset_row()],
          optional(:own_review) => review_row() | nil,
          optional(:latest_review_at) => DateTime.t() | nil,
          optional(:has_earlier_reviews) => boolean(),
          optional(:parent) => tip_row()
        }

  @typedoc """
  One inbox row. `tip` is the target tip or a review's parent, masked like
  every other link. `review_id` is set for review targets. `actor` names the
  reviewer of a `:tip_reviewed` row only while the review is readable; vote
  rows never name voters or carry their event count.
  """
  @type inbox_entry :: %{
          id: pos_integer(),
          type: Notification.type(),
          unread: boolean(),
          updated_at: DateTime.t(),
          tip: tip_link(),
          review_id: pos_integer() | nil,
          actor: author() | nil
        }

  @typedoc "Tip hydration and, only when the review is readable, review hydration."
  @type selected_hydration :: %{
          required(:tip) => hydration(),
          optional(:review) => hydration()
        }

  @typep scope :: Scope.t() | nil
  @typep tip_row :: %Tip{}
  @typep review_row :: %Review{}
  @typep asset_row :: %Asset{}
  @typep notification_row :: %Notification{}

  @doc """
  Projects a tip's title and slug for page titles, slug redirects, social
  previews and parent links. Needs no hydration.
  """
  @spec metadata(scope(), tip_row()) :: tip_link()
  def metadata(scope, %Tip{} = tip) do
    case Visibility.decision(scope, tip) do
      :visible -> %{state: :visible, id: tip.id, title: tip.title, slug: slug(tip.title)}
      state -> placeholder(state, tip.id)
    end
  end

  @doc """
  Projects a browse or search row.

  Requires `:author`, `:labels` and `:viewer_vote` for a readable tip.
  """
  @spec summary(scope(), tip_row(), hydration()) :: summary()
  def summary(scope, %Tip{} = tip, hydration) do
    case metadata(scope, tip) do
      %{state: :visible} = link -> visible_summary(link, scope, tip, hydration)
      placeholder -> placeholder
    end
  end

  @doc """
  Projects tip page context.

  Requires the `summary/3` keys plus `:media`, `:own_review`,
  `:latest_review_at` and `:has_earlier_reviews` for a readable tip.
  """
  @spec tip(scope(), tip_row(), hydration()) :: tip_detail()
  def tip(scope, %Tip{} = tip, hydration) do
    case metadata(scope, tip) do
      %{state: :visible} = link ->
        link
        |> visible_summary(scope, tip, hydration)
        |> Map.merge(%{
          body: tip.body,
          prompt: tip.prompt,
          output: tip.output,
          edited_at: tip.edited_at,
          up_count: tip.up_count,
          down_count: tip.down_count,
          latest_review_at: Map.fetch!(hydration, :latest_review_at),
          has_earlier_reviews: Map.fetch!(hydration, :has_earlier_reviews),
          capabilities: tip_capabilities(scope, tip, own_review!(hydration, scope, tip)),
          media: media(scope, tip, Map.fetch!(hydration, :media))
        })

      placeholder ->
        placeholder
    end
  end

  @doc """
  Projects a review with its masked parent context.

  Always requires `:parent`. Also requires `:author`, `:labels`,
  `:viewer_vote` and `:media` for a readable review.
  """
  @spec review(scope(), review_row(), hydration()) :: review_view()
  def review(scope, %Review{} = review, hydration) do
    parent = parent!(hydration, review)
    tip = metadata(scope, parent)

    case Visibility.decision(scope, review) do
      :visible ->
        %{
          state: :visible,
          id: review.id,
          tip: tip,
          removed: not is_nil(review.dead_at),
          body: review.body,
          prompt: review.prompt,
          output: review.output,
          model: model(hydration, review),
          environment: environment(hydration, review),
          author: author(hydration, review),
          by_tip_author: tip.state == :visible and review.user_id == parent.user_id,
          created_at: review.created_at,
          edited_at: review.edited_at,
          score: review.score,
          up_count: review.up_count,
          down_count: review.down_count,
          viewer_vote: viewer_vote(hydration),
          capabilities: capabilities(scope, review),
          media: media(scope, review, Map.fetch!(hydration, :media))
        }

      state ->
        %{state: state, id: review.id, tip: tip}
    end
  end

  @doc """
  Projects a selected-review destination: tip context plus one tagged result.

  Parent membership is checked before any review content or removal cause is
  considered, so `nil` and a review of another tip give the same result.
  `hydration.tip` follows `tip/3`; `hydration.review` follows `review/3`
  without `:parent`, and is read only for a readable review.
  """
  @spec selected_review(scope(), tip_row(), review_row() | nil, selected_hydration()) ::
          selected_review()
  def selected_review(scope, %Tip{} = tip, review, hydration) do
    %{
      tip: tip(scope, tip, Map.fetch!(hydration, :tip)),
      review: selected(scope, tip, review, hydration)
    }
  end

  @doc """
  Projects the viewer's own undeleted review for the tip page header link.

  Pass the row from the own-review lookup, or `nil` when there is none.
  Passing a row without a signed-in scope, or another user's row, raises
  `FunctionClauseError`: it is a caller bug, not an unavailable review.
  """
  @spec own_review(scope(), review_row() | nil) :: own_review() | nil
  def own_review(_scope, nil), do: nil

  def own_review(%Scope{user: %User{id: user_id}} = scope, %Review{user_id: user_id} = review) do
    case Visibility.decision(scope, review) do
      :visible ->
        %{
          id: review.id,
          removed: not is_nil(review.dead_at),
          capabilities: capabilities(scope, review)
        }

      _unavailable ->
        nil
    end
  end

  @doc """
  Projects an inbox row. `tip` is the notified tip, or the parent of the
  notified `review`. `author` is the review's author when the row names it, else
  `nil`. A target that does not match the row raises `FunctionClauseError`.
  """
  @spec inbox_entry(scope(), notification_row(), tip_row(), review_row() | nil, User.t() | nil) ::
          inbox_entry()
  def inbox_entry(scope, %Notification{} = notification, %Tip{} = tip, review, author) do
    %{
      id: notification.id,
      type: notification.type,
      unread: is_nil(notification.read_at),
      updated_at: notification.updated_at,
      tip: metadata(scope, target_tip!(notification, tip, review)),
      review_id: notification.review_id,
      actor: actor(scope, notification, review, author)
    }
  end

  defp target_tip!(%Notification{tip_id: id, review_id: nil}, %Tip{id: id} = tip, nil), do: tip

  defp target_tip!(
         %Notification{tip_id: nil, review_id: id},
         %Tip{id: tip_id} = tip,
         %Review{id: id, tip_id: tip_id}
       ),
       do: tip

  defp actor(scope, %Notification{type: :tip_reviewed}, review, author) do
    if Visibility.decision(scope, review) == :visible, do: author(%{author: author}, review)
  end

  defp actor(_scope, _notification, _review, _author), do: nil

  @doc """
  Projects the full text of one source of a matched review, for a search
  excerpt. The search consumer bounds the text.

  Returns `nil` unless the review is visible to `scope` and the source has
  text. A `:setup` text is the review's own model and environment labels,
  joined by " · ". Always requires `:parent`; `:setup` also requires `:labels`.
  """
  @spec excerpt(scope(), review_row(), excerpt_source(), hydration()) :: excerpt() | nil
  def excerpt(scope, %Review{} = review, source, hydration)
      when source in [:body, :prompt, :result, :setup] do
    parent!(hydration, review)

    with :visible <- Visibility.decision(scope, review),
         text when is_binary(text) <- excerpt_text(review, source, hydration) do
      %{source: source, text: text}
    else
      _unavailable -> nil
    end
  end

  @doc """
  Projects attachments of a tip or review.

  Returns `[]` unless the parent is visible to `scope`. Otherwise keeps only
  assets attached to this parent at a live position, skipping cleanup-marked,
  other-parent, staged and unready video rows, in position order. Draft and
  staged previews are the media consumer's own authorized read.
  """
  @spec media(scope(), tip_row() | review_row(), [asset_row()]) :: [media_item()]
  def media(scope, parent, assets) when is_list(assets) do
    case Visibility.decision(scope, parent) do
      :visible ->
        assets
        |> Enum.filter(&(attached_to?(&1, parent) and playable?(&1)))
        |> Enum.sort_by(& &1.position)
        |> Enum.map(&media_item/1)

      _unavailable ->
        []
    end
  end

  defp visible_summary(link, scope, tip, hydration) do
    Map.merge(link, %{
      removed: not is_nil(tip.dead_at),
      tag: tag(hydration, tip),
      model: model(hydration, tip),
      environment: environment(hydration, tip),
      author: author(hydration, tip),
      created_at: tip.created_at,
      score: tip.score,
      review_count: tip.review_count,
      viewer_vote: viewer_vote(hydration),
      capabilities: capabilities(scope, tip)
    })
  end

  defp placeholder(:deleted, id),
    do: %{state: :deleted, id: id, title: @deleted_title, slug: "deleted-tip"}

  defp placeholder(:removed, id),
    do: %{state: :removed, id: id, title: @removed_title, slug: "removed-tip"}

  defp selected(_scope, _tip, nil, _hydration), do: :unavailable

  defp selected(scope, %Tip{id: tip_id} = tip, %Review{tip_id: tip_id} = review, hydration) do
    case Visibility.decision(scope, review) do
      :visible ->
        review_hydration = hydration |> Map.fetch!(:review) |> Map.put(:parent, tip)
        {:visible, review(scope, review, review_hydration)}

      state ->
        state
    end
  end

  defp selected(_scope, _tip, %Review{}, _hydration), do: :unavailable

  defp excerpt_text(review, :body, _hydration), do: review.body
  defp excerpt_text(review, :prompt, _hydration), do: review.prompt
  defp excerpt_text(review, :result, _hydration), do: review.output

  defp excerpt_text(review, :setup, hydration) do
    case Enum.reject([model(hydration, review), environment(hydration, review)], &is_nil/1) do
      [] -> nil
      labels -> Enum.map_join(labels, " · ", & &1.label)
    end
  end

  @doc "The `scope`'s capability hints for a current tip or review row."
  @spec capabilities(scope(), tip_row() | review_row()) :: capabilities()
  def capabilities(scope, content) do
    contribute? = eligible?(scope, :contribute)
    own? = own?(scope, content)
    undeleted? = is_nil(content.deleted_at)
    live? = undeleted? and is_nil(content.dead_at)

    %{
      vote: contribute? and live?,
      edit: contribute? and own? and undeleted?,
      delete: own? and undeleted? and eligible?(scope, :delete_own_content),
      report: contribute? and live?
    }
  end

  defp tip_capabilities(scope, tip, own_review) do
    capabilities = capabilities(scope, tip)
    Map.put(capabilities, :review, capabilities.vote and is_nil(own_review))
  end

  defp eligible?(%Scope{user: user}, operation),
    do: Accounts.check_eligibility(user, operation) == :ok

  defp eligible?(nil, _operation), do: false

  defp own?(%Scope{user: %User{id: id}}, %{user_id: id}), do: true
  defp own?(_scope, _content), do: false

  defp author(hydration, %{user_id: author_id}) do
    case Map.fetch!(hydration, :author) do
      %User{id: ^author_id, deleted_at: nil, handle: handle} -> %{handle: handle}
      %User{id: ^author_id} -> :deleted_account
      %User{} -> raise ArgumentError, "author hydration does not belong to this content"
    end
  end

  defp parent!(hydration, %Review{tip_id: tip_id}) do
    case Map.fetch!(hydration, :parent) do
      %Tip{id: ^tip_id} = parent -> parent
      %Tip{} -> raise ArgumentError, "parent hydration is not this review's tip"
    end
  end

  defp own_review!(hydration, scope, %Tip{id: tip_id}) do
    case {Map.fetch!(hydration, :own_review), scope} do
      {nil, _scope} ->
        nil

      {%Review{tip_id: ^tip_id, user_id: user_id, deleted_at: nil} = review,
       %Scope{user: %User{id: user_id}}} ->
        review

      {%Review{}, _scope} ->
        raise ArgumentError,
              "own_review hydration is not this viewer's undeleted review of this tip"
    end
  end

  defp viewer_vote(hydration) do
    case Map.fetch!(hydration, :viewer_vote) do
      vote when vote in [-1, 1, nil] -> vote
    end
  end

  defp tag(hydration, %Tip{tag_id: id}), do: label(hydration, :tags, id)

  defp model(_hydration, %{model_id: nil, model_other: nil}), do: nil
  defp model(_hydration, %{model_id: nil, model_other: other}), do: %{id: nil, label: other}
  defp model(hydration, %{model_id: id}), do: label(hydration, :models, id)

  defp environment(_hydration, %{environment_id: nil}), do: nil
  defp environment(hydration, %{environment_id: id}), do: label(hydration, :environments, id)

  defp label(hydration, table, id) do
    %{id: id, label: hydration |> Map.fetch!(:labels) |> Map.fetch!(table) |> Map.fetch!(id)}
  end

  defp attached_to?(%Asset{cleanup_at: nil, position: position} = asset, parent)
       when is_integer(position),
       do: member?(asset, parent)

  defp attached_to?(%Asset{}, _parent), do: false

  defp member?(%Asset{tip_id: id, review_id: nil}, %Tip{id: id}), do: true
  defp member?(%Asset{tip_id: nil, review_id: id}, %Review{id: id}), do: true
  defp member?(%Asset{}, _parent), do: false

  defp playable?(%Asset{kind: :image}), do: true
  defp playable?(%Asset{kind: :video, state: :ready}), do: true
  defp playable?(%Asset{}), do: false

  defp media_item(%Asset{kind: :image} = asset) do
    %{
      kind: :image,
      id: asset.id,
      position: asset.position,
      description: asset.description,
      animated: asset.is_animated,
      object_key: asset.key
    }
  end

  defp media_item(%Asset{kind: :video} = asset) do
    %{
      kind: :video,
      id: asset.id,
      position: asset.position,
      duration_s: asset.duration_s,
      watch_path: "/media/#{asset.id}/watch",
      thumbnail_path: "/media/#{asset.id}/thumbnail"
    }
  end

  # Slugs are generated from the projected title, never stored. Non-ASCII-only
  # titles fall back to a neutral word; the id still resolves the page.
  defp slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.slice(0, 80)
    |> String.trim("-")
    |> non_empty_slug()
  end

  defp non_empty_slug(""), do: "tip"
  defp non_empty_slug(slug), do: slug
end
