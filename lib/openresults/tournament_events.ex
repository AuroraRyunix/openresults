defmodule OpenResults.TournamentEvents do
  @moduledoc """
  "Something about this tournament changed" - said on a PubSub topic per
  slug, for the one page on this site that keeps a connection open: the hall
  display (`OpenResultsWeb.HallLive`).

  Every other public page is a static document that polls (see the root
  layout's refresher), and none of them listens here. The message carries the
  slug and nothing else on purpose: a listener re-reads the tournament
  through `OpenResults.Tournaments.public_latest/1`, the same door every
  public page uses, so visibility is decided in one place and a message can
  never smuggle a hidden tournament's data to a screen.

  Sent from the two places a public page's answer can change:

    * `OpenResults.Snapshots.ingest/2`, after a publish is stored - the
      arbiter's result reaching the hall within a second rather than at the
      next poll;
    * `OpenResults.Tournaments`' `changed/1`, the one place a status change,
      a takedown or a release tells the read path - so a tournament an
      operator hides leaves the hall's screen as well.

  Broadcasting to a topic nobody subscribed to costs a registry lookup, so
  the tournaments nobody is projecting pay nothing for this.
  """

  @pubsub OpenResults.PubSub

  @doc "The topic for `slug`."
  @spec topic(String.t()) :: String.t()
  def topic(slug) when is_binary(slug), do: "tournament:" <> slug

  @doc "Subscribes the calling process to `slug`'s changes."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(slug) when is_binary(slug), do: Phoenix.PubSub.subscribe(@pubsub, topic(slug))

  @doc """
  Tells every subscriber that `slug` changed: they receive
  `{:tournament_changed, slug}`.
  """
  @spec changed(String.t()) :: :ok
  def changed(slug) when is_binary(slug) do
    Phoenix.PubSub.broadcast(@pubsub, topic(slug), {:tournament_changed, slug})
    :ok
  end
end
