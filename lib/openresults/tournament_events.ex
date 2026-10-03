defmodule OpenResults.TournamentEvents do
  @moduledoc """
  "Something about this tournament changed" - said on a PubSub topic per
  slug, for the two kinds of listener this site has:

    * the hall display (`OpenResultsWeb.HallLive`), a LiveView that re-reads
      the tournament on the message;
    * every other public page, through its event stream
      (`OpenResultsWeb.EventsController`): the page stays a static document
      that polls, and the stream only tells its refresher to poll NOW rather
      than up to twenty seconds later.

  The message carries the slug and nothing else on purpose: a listener
  re-reads the tournament through `OpenResults.Tournaments.public_latest/1`
  (or the page's own URL), the same door every public page uses, so
  visibility is decided in one place and a message can never smuggle a
  hidden tournament's data to a screen.

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
  Undoes `subscribe/1`. For a process that outlives its interest in `slug` -
  an HTTP connection that served an event stream and goes on to serve the
  next request on the same keep-alive connection.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(slug) when is_binary(slug),
    do: Phoenix.PubSub.unsubscribe(@pubsub, topic(slug))

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
