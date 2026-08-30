defmodule OpenResults.Build do
  @moduledoc """
  Which build this is, precisely enough to answer "did my deploy land?"

  ## Why this app in particular

  On 2026-08-30 a deploy went out and the public player pages still looked
  like the old ones. The version said `0.1.0`, which it had said for weeks,
  so there was nothing on the screen to check. The cause turned out to be
  that the deploy script builds OpenPairings by default and needs
  `--openresults` to touch this app at all - so it had never been deployed.

  A version number could not have shown that. A build identifier does, and
  it is put in the FOOTER of every page rather than behind a login, because
  this site has no login and the person asking the question is looking at it
  from outside.

  ## What identifies a build

  Resolved at COMPILE time and frozen into the beam: the release from
  `mix.exs`, the commit from `BUILD_REF` (the deploy sets it, because the
  uploaded tree has no `.git`), and when the beam was compiled.

  The timestamp earns its place: rebuilding the same commit to rule the
  build out is the commonest move when a deploy is in doubt, and the ref
  alone cannot tell those two apart.

  Mirrors `PairingsEngine.Build` deliberately. The two applications are
  separate on purpose - separate trees, separate units, separate databases -
  and a shared dependency for eleven lines would be the wrong kind of
  coupling. What matters is that both answer the question in the same shape,
  so one glance compares them.
  """

  @version Mix.Project.config()[:version]

  @env Mix.env()

  @ref (case System.get_env("BUILD_REF") do
          ref when is_binary(ref) and ref != "" ->
            String.trim(ref)

          _ ->
            try do
              case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
                {out, 0} -> String.trim(out)
                _ -> "unknown"
              end
            rescue
              _ -> "unknown"
            end
        end)

  @built_at DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "The release, from `mix.exs`."
  def version, do: @version

  @doc "The commit this was built from, or `\"unknown\"`."
  def ref, do: @ref

  @doc "When this beam was compiled, ISO-8601 UTC."
  def built_at, do: @built_at

  @doc "Whether this is a release build."
  def release?, do: @env == :prod

  @doc "The short identifier, for the footer: `\"0.1.0+3f2a1c9\"`."
  def id do
    cond do
      not release?() -> "#{@version}-dev"
      @ref == "unknown" -> "#{@version}+unknown"
      true -> "#{@version}+#{@ref}"
    end
  end

  @doc "The full identifier, for the footer's tooltip."
  def long do
    if release?() do
      "#{id()}, built #{built_at()}"
    else
      "#{id()} (not a release build)"
    end
  end
end
