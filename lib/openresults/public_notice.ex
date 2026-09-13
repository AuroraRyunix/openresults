defmodule OpenResults.PublicNotice do
  @moduledoc """
  A short message from the operator on every public page - "Maintenance
  tonight 22:00-22:30". Set, changed and cleared from the admin panel
  (`OpenResults.Moderation.set_public_notice/2`, `clear_public_notice/1`).

  ## What a notice is

    * `en` - required; `nl` and `fr` optional, and a page in a language the
      notice has no text for shows the English (marked `lang="en"`);
    * plain text, one line, at most 300 characters each. It is escaped
      where it is rendered, and `<` and `>` are refused outright: somebody
      typing a tag expects it to do something, and it will not;
    * `level` - `info` or `warning`;
    * `expires_at` - optional. After it the notice stops showing by itself:
      `current/1` compares it with the clock on every request, so no admin
      action and no job is needed.

  ## Why it has a version

  Public pages are cached - rendered bodies in ETS, and in the reader's own
  browser behind an ETag (`OpenResultsWeb.Plugs.Revalidate`) - and a notice
  changes every page without changing any snapshot. So the notice showing on
  a request has a `version`: `nil` when none is showing, otherwise a random
  revision drawn when it was set. It is part of the ETag's MAC input, and the
  ETag is part of the page cache's key, so setting, changing, clearing or
  expiring a notice gives
  every page a new tag: no 304 for a page rendered under another notice, and
  no cached body rendered under one. `OpenResultsWeb.Plugs.PublicNotice`
  decides it once per request, and both the tag and the layout read that one
  answer, so the two cannot disagree about a notice that expired mid-request.
  """

  import Ecto.Changeset

  alias OpenResults.ServerSettings

  @max_length 300
  @levels ~w(info warning)
  @languages ~w(en nl fr)

  @type t :: %{
          en: String.t(),
          nl: String.t() | nil,
          fr: String.t() | nil,
          level: String.t(),
          expires_at: DateTime.t() | nil,
          set_at: DateTime.t(),
          revision: String.t() | nil,
          set_by: String.t() | nil
        }

  @doc "The most characters one language's text may have."
  def max_length, do: @max_length

  @doc "The two levels."
  def levels, do: @levels

  @doc "The stored notice, expired or not, or `nil`."
  @spec stored() :: t() | nil
  def stored do
    case ServerSettings.notice_document() do
      %{} = doc -> from_document(doc)
      nil -> nil
    end
  end

  @doc "The notice showing at `now`: stored and not expired. Otherwise `nil`."
  @spec current(DateTime.t()) :: t() | nil
  def current(now \\ DateTime.utc_now()) do
    case stored() do
      nil -> nil
      notice -> if active?(notice, now), do: notice
    end
  end

  @doc "Whether `notice` is showing at `now`."
  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(%{expires_at: nil}, _now), do: true
  def active?(%{expires_at: at}, now), do: DateTime.compare(now, at) == :lt

  @doc """
  What a page in `locale` shows: `%{text, lang, level, version}`. `lang` is
  the language the text is actually in, which is English when the notice has
  none in `locale`.
  """
  @spec for_locale(t(), String.t()) :: map()
  def for_locale(notice, locale) do
    {text, lang} =
      case {locale, notice} do
        {"nl", %{nl: text}} when is_binary(text) -> {text, "nl"}
        {"fr", %{fr: text}} when is_binary(text) -> {text, "fr"}
        _english -> {notice.en, "en"}
      end

    %{text: text, lang: lang, level: notice.level, version: version(notice)}
  end

  @doc "The version a page is keyed on: the revision drawn when the notice was set."
  @spec version(t() | nil) :: String.t() | nil
  def version(nil), do: nil
  def version(%{revision: revision}) when is_binary(revision), do: revision
  def version(%{set_at: at}), do: DateTime.to_iso8601(at)

  @doc """
  Checks a notice as the panel's form sends it - string keys `en`, `nl`,
  `fr`, `level`, `expires_at` (ISO 8601, or blank for none) - against `now`.
  Stores nothing.
  """
  @spec changeset(map(), DateTime.t()) :: Ecto.Changeset.t()
  def changeset(attrs, now \\ DateTime.utc_now()) when is_map(attrs) do
    types = %{en: :string, nl: :string, fr: :string, level: :string, expires_at: :utc_datetime}

    attrs =
      Map.new(["en", "nl", "fr", "level", "expires_at"], fn key ->
        value = Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key))
        {key, if(is_binary(value), do: squish(value), else: value)}
      end)

    {%{}, types}
    |> cast(attrs, Map.keys(types), empty_values: [nil, ""])
    |> validate_required([:en], message: "is required")
    |> validate_inclusion(:level, @levels)
    |> validate_required([:level])
    |> validate_text(:en)
    |> validate_text(:nl)
    |> validate_text(:fr)
    |> validate_change(:expires_at, fn :expires_at, at ->
      if DateTime.compare(at, now) == :gt, do: [], else: [expires_at: "must be in the future"]
    end)
    |> Map.put(:action, :validate)
  end

  defp validate_text(changeset, field) do
    changeset
    |> validate_length(field, max: @max_length)
    |> validate_format(field, ~r/\A[^<>]*\z/u, message: "is plain text")
  end

  # One line: runs of whitespace, newlines included, become one space.
  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  @doc false
  # The stored document for a valid changeset.
  def to_document(%Ecto.Changeset{valid?: true} = changeset, set_by, now) do
    %{
      "en" => get_field(changeset, :en),
      "nl" => get_field(changeset, :nl),
      "fr" => get_field(changeset, :fr),
      "level" => get_field(changeset, :level),
      "expires_at" =>
        case get_field(changeset, :expires_at) do
          nil -> nil
          at -> DateTime.to_iso8601(at)
        end,
      "set_at" => DateTime.to_iso8601(now),
      # What the version is: random, so two notices set within the clock's
      # resolution (a Windows clock ticks in milliseconds) still differ.
      "revision" => 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
      "set_by" => set_by
    }
  end

  @doc false
  def from_document(doc) do
    %{
      en: text(doc["en"]) || "",
      nl: text(doc["nl"]),
      fr: text(doc["fr"]),
      level: if(doc["level"] in @levels, do: doc["level"], else: "info"),
      expires_at: instant(doc["expires_at"]),
      set_at: instant(doc["set_at"]) || ~U[1970-01-01 00:00:00Z],
      revision: if(is_binary(doc["revision"]), do: doc["revision"]),
      set_by: doc["set_by"]
    }
  end

  @doc false
  # What the action log keeps of a notice: everything but who set it, which
  # is the row's own actor.
  def log_details(nil), do: nil

  def log_details(notice) do
    %{
      "en" => notice.en,
      "nl" => notice.nl,
      "fr" => notice.fr,
      "level" => notice.level,
      "expires_at" => notice.expires_at && DateTime.to_iso8601(notice.expires_at)
    }
  end

  @doc "The languages a notice can carry."
  def languages, do: @languages

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp instant(_), do: nil
end
