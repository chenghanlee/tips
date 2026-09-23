defmodule Tips.Content.ProjectionContractTest.Consumer do
  @moduledoc """
  Representative web-layer consumers written only against the declared projection
  types. It compiles with this test and uses no Content query APIs.
  """

  alias Tips.Content.Projection

  @spec summary_row(Projection.summary()) :: String.t()
  def summary_row(%{
        state: :visible,
        title: title,
        slug: slug,
        tag: %{id: tag_id, label: tag_label},
        model: model,
        environment: environment,
        author: author,
        score: score,
        review_count: review_count,
        viewer_vote: vote,
        capabilities: %{vote: can_vote?}
      }) do
    Enum.join(
      [
        "#{title} (#{slug})",
        "#{tag_label}[#{tag_id}]",
        setup_label(model),
        setup_label(environment),
        author_label(author),
        "score #{score}",
        "#{review_count} reviews",
        "vote #{inspect(vote)}",
        "can vote #{can_vote?}"
      ],
      " | "
    )
  end

  def summary_row(%{state: state, title: title, slug: slug}) when state in [:deleted, :removed],
    do: "#{title} (#{slug})"

  @spec detail_header(Projection.tip_detail()) :: String.t()
  def detail_header(%{
        state: :visible,
        body: body,
        up_count: up,
        down_count: down,
        latest_review_at: latest,
        has_earlier_reviews: earlier?,
        removed: removed?,
        media: media,
        capabilities: %{review: can_review?, edit: can_edit?, delete: can_delete?}
      }) do
    notice = if removed?, do: "Removed by moderators. ", else: ""
    latest = if latest, do: "latest review #{DateTime.to_date(latest)}", else: "no reviews"

    "#{notice}#{body} +#{up}/-#{down}, #{latest}, earlier #{earlier?}, " <>
      "review #{can_review?}, edit #{can_edit?}, delete #{can_delete?}, " <>
      Enum.map_join(media, ",", &media_ref/1)
  end

  def detail_header(%{state: state, title: title}) when state in [:deleted, :removed], do: title

  @spec page_title(Projection.tip_link()) :: {String.t(), String.t()}
  def page_title(%{title: title, slug: slug}), do: {title, slug}

  @spec selected(Projection.selected_review()) :: String.t()
  def selected(%{tip: tip, review: review}) do
    context = detail_header(tip)

    case review do
      {:visible, %{body: body, by_tip_author: by_author?, tip: %{title: parent}}} ->
        "#{context} / #{parent}: #{body}#{if by_author?, do: " (tip author)", else: ""}"

      :deleted ->
        "#{context} / Review deleted by author"

      :removed ->
        "#{context} / Review removed by moderators"

      :unavailable ->
        "#{context} / Review unavailable"
    end
  end

  @spec own_review_link(Projection.own_review() | nil) :: String.t() | nil
  def own_review_link(nil), do: nil

  def own_review_link(%{
        id: id,
        removed: removed?,
        capabilities: %{edit: edit?, delete: delete?}
      }),
      do: "review #{id} removed=#{removed?} edit=#{edit?} delete=#{delete?}"

  @spec excerpt_label(Projection.excerpt()) :: String.t()
  def excerpt_label(%{source: source, text: text}) do
    label =
      case source do
        :body -> "Review"
        :prompt -> "Prompt"
        :result -> "Result"
        :setup -> "Reviewer setup"
      end

    "#{label}: #{text}"
  end

  @spec media_ref(Projection.media_item()) :: String.t()
  def media_ref(%{kind: :image, object_key: key, description: description, animated: animated?}),
    do: "image #{key} #{description} animated=#{animated?}"

  def media_ref(%{kind: :video, watch_path: watch, thumbnail_path: thumbnail, duration_s: s}),
    do: "video #{watch} #{thumbnail} #{s}s"

  defp setup_label(nil), do: "unspecified"
  defp setup_label(%{id: nil, label: label}), do: label
  defp setup_label(%{id: id, label: label}), do: "#{label}[#{id}]"

  defp author_label(%{handle: handle}), do: handle
  defp author_label(:deleted_account), do: "[deleted]"
end

defmodule Tips.Content.ProjectionContractTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts.Scope
  alias Tips.Content.Projection
  alias Tips.Content.ProjectionContractTest.Consumer

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.VisibilityFixtures

  test "consumer examples compile against narrow projection contracts" do
    author = user_fixture()
    reviewer = user_fixture()
    viewer = Scope.for_user(reviewer)

    tip =
      tip_fixture(author, %{
        title: "Name the output format",
        model_id: "claude",
        environment_id: "ide"
      })

    [image, video] = [image_fixture(tip), attached_video_fixture(tip, %{position: 1})]
    review = review_fixture(tip, %{user_id: reviewer.id, body: "Worked for JSON output."})
    vote_fixture(tip, %{user_id: reviewer.id})
    tip = Repo.reload!(tip)

    tip_hydration = %{
      author: author,
      labels: labels(),
      viewer_vote: 1,
      media: [video, image],
      own_review: review,
      latest_review_at: review.created_at,
      has_earlier_reviews: false
    }

    review_hydration = %{
      author: reviewer,
      labels: labels(),
      viewer_vote: nil,
      media: []
    }

    assert Consumer.summary_row(Projection.summary(viewer, tip, tip_hydration)) ==
             "Name the output format (name-the-output-format) | Other technique[other] | " <>
               "Claude[claude] | IDE[ide] | #{author.handle} | score 1 | 1 reviews | " <>
               "vote 1 | can vote true"

    assert Consumer.detail_header(Projection.tip(viewer, tip, tip_hydration)) =~
             "review false, edit false, delete false, image #{image.key}"

    assert Consumer.page_title(Projection.metadata(nil, tip)) ==
             {"Name the output format", "name-the-output-format"}

    assert Consumer.selected(
             Projection.selected_review(viewer, tip, review, %{
               tip: tip_hydration,
               review: review_hydration
             })
           ) =~ "Name the output format: Worked for JSON output."

    assert Consumer.own_review_link(Projection.own_review(viewer, review)) ==
             "review #{review.id} removed=false edit=true delete=true"

    assert Consumer.excerpt_label(%{source: :setup, text: "Claude in IDE"}) ==
             "Reviewer setup: Claude in IDE"

    deleted = put_marker!(tip, :deleted)

    assert Consumer.summary_row(Projection.summary(viewer, deleted, tip_hydration)) ==
             "Deleted tip (deleted-tip)"
  end
end
