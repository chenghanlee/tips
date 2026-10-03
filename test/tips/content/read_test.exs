defmodule Tips.Content.ReadTest do
  @moduledoc """
  Acceptance evidence for #76: the tip and selected-review destinations behind
  `Tips.Content`, read from fixture rows with real session admission.
  """
  use Tips.DataCase, async: true

  alias Tips.Accounts
  alias Tips.Accounts.{Scope, SessionRef, User, UserToken}
  alias Tips.Content

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.VisibilityFixtures

  @sentinel "SENTINEL"

  describe "tip page" do
    test "tip projection masks deleted originals for every viewer and hidden originals for outsiders" do
      author = user_fixture(%{handle: "sentinel#{System.unique_integer([:positive])}"})
      tip = sentinel_tip(author)

      media = [
        image_fixture(tip, %{description: "#{@sentinel} image"}),
        attached_video_fixture(tip, %{position: 1})
      ]

      private = [author.handle, tip.submission_key | private_media_values(media)]
      %{ref: owner} = session(author)

      check = fn viewers ->
        for marker <- markers(), {viewer, ref} <- viewers do
          put_marker!(tip, marker)
          label = {marker, viewer}

          case expected_state(marker, viewer, [:owner, :moderator, :banned_owner]) do
            :visible ->
              assert {:ok,
                      %{
                        tip:
                          %{state: :visible, title: "SENTINEL title", body: "SENTINEL body"} =
                            view
                      }} =
                       Content.get_tip_page(ref, tip.id)

              assert_plain(view)
              refute inspect(view) =~ tip.submission_key

            state ->
              result = Content.get_tip_page(ref, tip.id)

              assert {label, {:ok, %{tip: placeholder(state, tip.id), own_review: nil}}} ==
                       {label, result}

              refute_leak(result, private, label)
          end
        end
      end

      check.(
        anonymous: nil,
        reader: session(user_fixture()).ref,
        owner: owner,
        moderator: session(moderator!(user_fixture())).ref
      )

      full_ban!(author)
      check.(banned_owner: owner)
    end

    test "unknown, malformed and out-of-range tip ids are not found" do
      %{ref: ref} = session(user_fixture())

      for viewer <- [nil, ref], id <- bad_ids() do
        assert {id, {:error, :not_found}} == {id, Content.get_tip_page(viewer, id)}
      end

      tip = tip_fixture()
      assert {:ok, %{tip: %{id: id}}} = Content.get_tip_page(nil, Integer.to_string(tip.id))
      assert id == tip.id
    end
  end

  describe "selected review" do
    test "selected review retains independent visibility under hidden and deleted parents" do
      tip_author = user_fixture()
      reviewer = user_fixture()
      tip = tip_fixture(tip_author, %{title: "Parent title", model_id: "gpt"})

      selected =
        review_fixture(tip, %{
          user_id: reviewer.id,
          body: "Selected body",
          model_id: "claude",
          environment_id: "cli",
          created_at: DateTime.add(DateTime.utc_now(:second), -3600)
        })

      # Competing reviews on the same tip rank above the selected one by votes and date.
      competitor =
        review_fixture(tip, %{body: "Competitor body", model_id: "gpt", environment_id: "ide"})

      vote_fixture(competitor)
      review_fixture(tip_fixture(), %{body: "Competitor elsewhere"})
      parent_id = tip.id

      viewers = [
        anonymous: nil,
        reader: session(user_fixture()).ref,
        reviewer: session(reviewer).ref,
        tip_author: session(tip_author).ref,
        moderator: session(moderator!(user_fixture())).ref
      ]

      for parent_marker <- markers(), review_marker <- markers(), {viewer, ref} <- viewers do
        put_marker!(tip, parent_marker)
        put_marker!(selected, review_marker)
        label = {parent_marker, review_marker, viewer}

        assert {:ok, %{tip: tip_view, review: review_view} = result} =
                 Content.get_review_page(ref, selected.id)

        case expected_state(parent_marker, viewer, [:tip_author, :moderator]) do
          :visible ->
            assert {label, %{state: :visible, id: ^parent_id, title: "Parent title"}} =
                     {label, tip_view}

          state ->
            assert {label, placeholder(state, tip.id)} == {label, tip_view}
        end

        case expected_state(review_marker, viewer, [:reviewer, :moderator]) do
          :visible ->
            assert {label,
                    {:visible,
                     %{
                       id: id,
                       body: "Selected body",
                       model: %{id: "claude", label: "Claude"},
                       environment: %{id: "cli", label: "CLI"},
                       tip: %{id: tip_id}
                     }}} = {label, review_view}

            assert {id, tip_id} == {selected.id, tip.id}

          state ->
            assert {label, state} == {label, review_view}
            refute inspect(result) =~ "Selected body"
        end

        refute inspect(result) =~ "Competitor"
      end
    end

    test "unknown, malformed and out-of-range review ids are not found" do
      %{ref: ref} = session(user_fixture())

      for viewer <- [nil, ref], id <- bad_ids() do
        assert {id, {:error, :not_found}} == {id, Content.get_review_page(viewer, id)}
      end

      review = review_fixture()

      assert {:ok, %{review: {:visible, %{id: id}}}} =
               Content.get_review_page(nil, Integer.to_string(review.id))

      assert id == review.id
    end
  end

  describe "admission" do
    test "anonymous reads do not query session tokens" do
      tip = tip_fixture()
      review = review_fixture(tip)
      %{ref: ref} = session(user_fixture())

      assert {{:ok, _}, sources} = capture_sources(fn -> Content.get_tip_page(nil, tip.id) end)
      refute "users_tokens" in sources

      assert {{:ok, _}, sources} =
               capture_sources(fn -> Content.get_review_page(nil, review.id) end)

      refute "users_tokens" in sources

      # The signed-in path does admit through the session row.
      assert {{:ok, _}, sources} = capture_sources(fn -> Content.get_tip_page(ref, tip.id) end)
      assert "users_tokens" in sources
    end

    test "revoked admission blocks both reads without a disconnect" do
      moderator = moderator!(user_fixture())
      %{token: token, ref: ref} = session(moderator)
      %{tip: tip, review: review} = hidden_pair()

      assert {:ok, %{tip: %{state: :visible}}} = Content.get_tip_page(ref, tip.id)
      assert {:ok, %{review: {:visible, _}}} = Content.get_review_page(ref, review.id)

      # Revocation deletes the rows; nobody broadcasts a disconnect.
      assert {:ok, [_family]} = Accounts.revoke_user_session_family(token)

      assert_unauthenticated(ref, tip, review)
    end

    test "expired sessions, deleted accounts, mismatched or malformed references and stale scopes fail admission" do
      moderator = moderator!(user_fixture())
      %{tip: tip, review: review} = hidden_pair()

      %{token: expired_token, ref: expired} = session(moderator)

      Repo.update_all(from(t in UserToken, where: t.token == ^expired_token),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -60, :day)]
      )

      assert_unauthenticated(expired, tip, review)

      %{ref: ref} = session(moderator)
      other = user_fixture()
      %{ref: other_ref} = session(other)

      for forged <- [
            %{ref | user_id: other.id},
            %{other_ref | user_id: moderator.id},
            %SessionRef{token_id: 0, user_id: moderator.id},
            %{token_id: ref.token_id, user_id: moderator.id},
            {ref.token_id, moderator.id},
            ref.token_id,
            "token",
            Scope.for_user(moderator)
          ] do
        assert_unauthenticated(forged, tip, review)
      end

      assert {:ok, %{tip: %{state: :visible}}} = Content.get_tip_page(ref, tip.id)
      delete_account!(moderator)
      assert_unauthenticated(ref, tip, review)
    end
  end

  describe "current account state" do
    test "current role and ban determine visibility and capabilities" do
      author = user_fixture()
      live = tip_fixture(author)
      hidden = put_marker!(tip_fixture(author, %{title: "Hidden title"}), :hidden)
      viewer = user_fixture()
      %{ref: ref} = session(viewer)

      assert {:ok, %{tip: %{state: :removed}}} = Content.get_tip_page(ref, hidden.id)

      assert {:ok,
              %{
                tip: %{
                  capabilities: %{
                    vote: true,
                    report: true,
                    review: true,
                    edit: false,
                    delete: false
                  }
                }
              }} =
               Content.get_tip_page(ref, live.id)

      viewer = update_user!(viewer, role: :moderator)

      assert {:ok, %{tip: %{state: :visible, removed: true, title: "Hidden title"}}} =
               Content.get_tip_page(ref, hidden.id)

      # A full ban preserves reading but not contributing.
      viewer = full_ban!(viewer)
      assert {:ok, %{tip: %{state: :visible}}} = Content.get_tip_page(ref, hidden.id)

      assert {:ok, %{tip: %{capabilities: %{vote: false, report: false, review: false}}}} =
               Content.get_tip_page(ref, live.id)

      viewer = update_user!(viewer, ban: nil, banned_at: nil, confirmed_at: nil)

      assert {:ok, %{tip: %{capabilities: %{vote: false, report: false, review: false}}}} =
               Content.get_tip_page(ref, live.id)

      update_user!(viewer, role: :user)
      assert {:ok, %{tip: %{state: :removed}}} = Content.get_tip_page(ref, hidden.id)
    end

    test "banned owner keeps own hidden review identity and delete beneath removed or deleted parents" do
      owner = user_fixture()
      tip = tip_fixture()

      review =
        put_marker!(review_fixture(tip, %{user_id: owner.id, body: "Own hidden body"}), :hidden)

      %{ref: ref} = session(owner)
      full_ban!(owner)

      capabilities = %{vote: false, edit: false, delete: true, report: false}

      for marker <- [:hidden, :deleted, :deleted_and_hidden] do
        put_marker!(tip, marker)
        state = if marker == :hidden, do: :removed, else: :deleted

        assert {marker,
                {:ok,
                 %{
                   tip: placeholder(state, tip.id),
                   own_review: %{id: review.id, removed: true, capabilities: capabilities}
                 }}} ==
                 {marker, Content.get_tip_page(ref, tip.id)}

        assert {:ok,
                %{
                  tip: tip_view,
                  review:
                    {:visible,
                     %{
                       id: id,
                       removed: true,
                       body: "Own hidden body",
                       capabilities: ^capabilities
                     }}
                }} =
                 Content.get_review_page(ref, review.id)

        assert {marker, placeholder(state, tip.id)} == {marker, tip_view}
        assert id == review.id
      end
    end
  end

  describe "hydration" do
    test "hydration returns only authorized evidence and current viewer data" do
      author = user_fixture()

      tip =
        tip_fixture(author, %{
          model_id: "claude",
          environment_id: "ide",
          prompt: "Tip prompt",
          output: "Tip output"
        })

      second = image_fixture(tip, %{position: 1, description: "Second"})
      first = image_fixture(tip, %{position: 0, is_animated: true})
      video = attached_video_fixture(tip, %{position: 2})
      cleanup = cleanup_media_fixture(tip, %{position: 3})

      staged =
        staged_video_fixture(author, %{
          state: :processing,
          stream_uid: "stream-#{Ecto.UUID.generate()}",
          target: {:edit_tip, tip.id}
        })

      reviewer = user_fixture()

      review =
        review_fixture(tip, %{
          user_id: reviewer.id,
          model_other: "Local model",
          prompt: "Review prompt",
          output: "Review output"
        })

      review_image = image_fixture(review, %{description: "Review image"})

      viewer = user_fixture()
      %{ref: ref} = session(viewer)
      vote_fixture(tip, %{user_id: viewer.id, value: -1})
      vote_fixture(tip)
      vote_fixture(review, %{user_id: viewer.id})

      assert {:ok, %{tip: tip_view, own_review: nil} = tip_page} =
               Content.get_tip_page(ref, tip.id)

      assert %{
               tag: %{id: "other", label: "Other technique"},
               model: %{id: "claude", label: "Claude"},
               environment: %{id: "ide", label: "IDE"},
               prompt: "Tip prompt",
               output: "Tip output",
               viewer_vote: -1,
               up_count: 1,
               down_count: 1,
               capabilities: %{review: true},
               media: [
                 %{kind: :image, id: first_id, animated: true},
                 %{kind: :image, id: second_id, description: "Second"},
                 %{kind: :video, id: video_id, watch_path: watch}
               ]
             } = tip_view

      assert {first_id, second_id, video_id} == {first.id, second.id, video.id}
      assert watch == "/media/#{video.id}/watch"
      assert %{tip: %{viewer_vote: nil}} = elem(Content.get_tip_page(nil, tip.id), 1)

      assert {:ok, %{review: {:visible, review_view}} = review_page} =
               Content.get_review_page(ref, review.id)

      assert %{
               model: %{id: nil, label: "Local model"},
               environment: nil,
               prompt: "Review prompt",
               output: "Review output",
               viewer_vote: 1,
               author: %{handle: handle},
               media: [%{kind: :image, id: image_id, description: "Review image"}]
             } = review_view

      assert {handle, image_id} == {reviewer.handle, review_image.id}

      for page <- [tip_page, review_page] do
        assert_plain(page)
        text = inspect(page, limit: :infinity, printable_limit: :infinity)

        for private <- [
              video.stream_uid,
              cleanup.stream_uid,
              staged.stream_uid,
              "/media/#{cleanup.id}/",
              "/media/#{staged.id}/"
            ] do
          refute text =~ private
        end
      end

      # Deleted accounts lose attribution.
      delete_account!(author)
      delete_account!(reviewer)
      assert {:ok, %{tip: %{author: :deleted_account}}} = Content.get_tip_page(ref, tip.id)

      assert {:ok, %{review: {:visible, %{author: :deleted_account}}}} =
               Content.get_review_page(ref, review.id)

      # The own-review header is identity and capabilities only.
      own = review_fixture(tip, %{user_id: viewer.id, body: "Own review body"})
      image_fixture(own)

      assert {:ok, %{own_review: own_view, tip: %{capabilities: %{review: false}}}} =
               Content.get_tip_page(ref, tip.id)

      assert own_view == %{
               id: own.id,
               removed: false,
               capabilities: %{vote: true, edit: true, delete: true, report: true}
             }

      put_marker!(own, :deleted)

      assert {:ok, %{own_review: nil, tip: %{capabilities: %{review: true}}}} =
               Content.get_tip_page(ref, tip.id)
    end
  end

  describe "review dates" do
    test "review dates obey current visibility" do
      now = DateTime.utc_now(:second)
      ago = &DateTime.add(now, -&1)
      author = user_fixture()
      reviewer = user_fixture()

      # Latest: live reviews only, never a newer hidden or deleted one.
      tip = tip_fixture(author)
      review_fixture(tip, %{created_at: ago.(300)})
      latest = review_fixture(tip, %{created_at: ago.(200)})
      put_marker!(review_fixture(tip, %{created_at: ago.(50)}), :hidden)
      put_marker!(review_fixture(tip, %{created_at: ago.(10)}), :deleted)

      moderator = session(moderator!(user_fixture())).ref

      for viewer <- [nil, moderator] do
        assert {:ok, %{tip: %{latest_review_at: at, has_earlier_reviews: false}}} =
                 Content.get_tip_page(viewer, tip.id)

        assert at == latest.created_at
      end

      # Earlier visible review before the edit.
      edited = tip_fixture(author, %{edited_at: ago.(100)})
      review_fixture(edited, %{created_at: ago.(150)})
      assert {:ok, %{tip: %{has_earlier_reviews: true}}} = Content.get_tip_page(nil, edited.id)

      # Only a hidden earlier review: its author and moderators read it.
      edited = tip_fixture(author, %{edited_at: ago.(100)})
      put_marker!(review_fixture(edited, %{user_id: reviewer.id, created_at: ago.(150)}), :hidden)
      put_marker!(review_fixture(edited, %{created_at: ago.(160)}), :deleted)
      review_fixture(edited, %{created_at: ago.(50)})

      for {viewer, expected} <- [
            anonymous: false,
            reader: false,
            reviewer: true,
            moderator: true
          ] do
        ref =
          case viewer do
            :anonymous -> nil
            :reader -> session(user_fixture()).ref
            :reviewer -> session(reviewer).ref
            :moderator -> moderator
          end

        assert {viewer, {:ok, expected}} ==
                 {viewer,
                  with(
                    {:ok, %{tip: tip}} <- Content.get_tip_page(ref, edited.id),
                    do: {:ok, tip.has_earlier_reviews}
                  )}
      end

      # An unreadable hidden tip returns no dates or edit metadata.
      put_marker!(edited, :hidden)

      assert {:ok, %{tip: placeholder(:removed, edited.id), own_review: nil}} ==
               Content.get_tip_page(nil, edited.id)
    end
  end

  defp session(%User{} = user) do
    token = Accounts.generate_user_session_token(user)
    {:ok, _scope, ref, _inserted_at} = Accounts.get_scope_by_session_token(token)
    %{token: token, ref: ref}
  end

  defp sentinel_tip(author) do
    tip_fixture(author, %{
      title: "#{@sentinel} title",
      body: "#{@sentinel} body",
      prompt: "#{@sentinel} prompt",
      output: "#{@sentinel} output",
      model_other: "#{@sentinel} model",
      environment_id: "cli"
    })
  end

  defp hidden_pair do
    tip = put_marker!(tip_fixture(), :hidden)
    review = put_marker!(review_fixture(tip), :hidden)
    %{tip: tip, review: review}
  end

  defp assert_unauthenticated(viewer, tip, review) do
    assert {viewer, {:error, :unauthenticated}} == {viewer, Content.get_tip_page(viewer, tip.id)}

    assert {viewer, {:error, :unauthenticated}} ==
             {viewer, Content.get_review_page(viewer, review.id)}
  end

  defp update_user!(user, changes), do: user |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp expected_state(marker, _viewer, _readers) when marker in [:deleted, :deleted_and_hidden],
    do: :deleted

  defp expected_state(:hidden, viewer, readers),
    do: if(viewer in readers, do: :visible, else: :removed)

  defp expected_state(:live, _viewer, _readers), do: :visible

  defp placeholder(:deleted, id),
    do: %{state: :deleted, id: id, title: "Deleted tip", slug: "deleted-tip"}

  defp placeholder(:removed, id),
    do: %{state: :removed, id: id, title: "Removed tip", slug: "removed-tip"}

  defp bad_ids do
    [
      9_000_000_000_000_000_000,
      0,
      -1,
      9_223_372_036_854_775_808,
      "9223372036854775808",
      "abc",
      "12abc",
      " 1",
      "",
      nil,
      1.0,
      %{},
      [1]
    ]
  end

  # Collects the table names this process queries while `fun` runs.
  defp capture_sources(fun) do
    test = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:tips, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test, do: send(test, {handler, metadata.source})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(handler, [])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, sources) do
    receive do
      {^handler, source} -> drain(handler, [source | sources])
    after
      0 -> sources
    end
  end

  defp private_media_values(assets) do
    Enum.flat_map(assets, fn asset ->
      Enum.reject(
        [asset.key, asset.stream_uid, asset.description, "/media/#{asset.id}/"],
        &is_nil/1
      )
    end)
  end

  defp refute_leak(output, private_values, label) do
    text = inspect(output, limit: :infinity, printable_limit: :infinity)

    for private <- [@sentinel | private_values] do
      refute text =~ private, "#{inspect(label)} leaked #{inspect(private)}"
    end
  end

  # Only plain maps, lists, tuples, atoms, numbers, strings and DateTime values may
  # leave a read; any other struct is a raw schema or association.
  defp assert_plain(%DateTime{}), do: :ok
  defp assert_plain(%{__struct__: struct}), do: flunk("read returned #{inspect(struct)}")
  defp assert_plain(map) when is_map(map), do: Enum.each(map, fn {_k, v} -> assert_plain(v) end)
  defp assert_plain(list) when is_list(list), do: Enum.each(list, &assert_plain/1)
  defp assert_plain(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> assert_plain()
  defp assert_plain(_scalar), do: :ok
end
