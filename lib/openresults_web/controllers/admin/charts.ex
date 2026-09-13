defmodule OpenResultsWeb.Admin.Charts do
  @moduledoc """
  Small charts for the admin stats page, drawn as SVG on the server.

  The panel runs no JavaScript and its CSP refuses inline styles, so a chart
  is plain SVG elements with classes (`assets/css/app.css`, "admin: stats").
  Every chart is a `role="img"` with a name saying what it shows and its
  latest value, and the same value is printed beside it: the line or the bars
  are never the only place a figure is.

  Missing values (`nil`: nothing sampled in that minute) leave a gap in a
  line and no bar, rather than a zero that did not happen.
  """
  use Phoenix.Component

  # The drawing area inside a 320 x 96 view box, labels on the left and
  # underneath. The template's axis lines and labels use the same numbers.
  @left 44
  @right 314
  @top 8
  @bottom 72

  attr :id, :string, required: true
  attr :title, :string, required: true, doc: "what the chart shows, e.g. requests per minute"
  attr :values, :list, required: true, doc: "numbers, or nil for no sample"
  attr :now, :string, required: true, doc: "the latest value, as text"
  attr :from, :string, required: true, doc: "the label under the first value"
  attr :to, :string, default: "now", doc: "the label under the last value"
  attr :max, :any, default: nil, doc: "a fixed top of the scale, e.g. 100 for a percentage"
  attr :format, :any, default: nil, doc: "formats the scale's top label"
  attr :kind, :atom, default: :line, values: [:line, :bars]

  def chart(assigns) do
    top = scale_top(assigns.values, assigns.max)
    format = assigns.format || (&short_number/1)

    assigns =
      assign(assigns,
        top: top,
        top_label: format.(top),
        shapes: shapes(assigns.kind, assigns.values, top)
      )

    ~H"""
    <figure class="admin-chart" id={@id}>
      <figcaption>
        <span class="admin-chart-title">{@title}</span>
        <strong class="admin-chart-now">{@now}</strong>
      </figcaption>
      <svg
        role="img"
        aria-label={"#{@title}, from #{@from} to #{@to}, scale 0 to #{@top_label}; latest #{@now}"}
        viewBox="0 0 320 96"
        class="admin-chart-svg"
      >
        <line class="admin-chart-axis" x1="44" y1="72" x2="314" y2="72" />
        <line class="admin-chart-axis" x1="44" y1="8" x2="44" y2="72" />
        <text class="admin-chart-label" x="40" y="12" text-anchor="end">{@top_label}</text>
        <text class="admin-chart-label" x="40" y="72" text-anchor="end">0</text>
        <text class="admin-chart-label" x="44" y="90" text-anchor="start">{@from}</text>
        <text class="admin-chart-label" x="314" y="90" text-anchor="end">{@to}</text>
        <%= for shape <- @shapes do %>
          <polyline :if={elem(shape, 0) == :line} class="admin-chart-line" points={elem(shape, 1)} />
          <circle
            :if={elem(shape, 0) == :dot}
            class="admin-chart-dot"
            cx={elem(shape, 1)}
            cy={elem(shape, 2)}
            r="1.5"
          />
          <rect
            :if={elem(shape, 0) == :bar}
            class="admin-chart-bar"
            x={elem(shape, 1)}
            y={elem(shape, 2)}
            width={elem(shape, 3)}
            height={elem(shape, 4)}
          />
        <% end %>
      </svg>
    </figure>
    """
  end

  @doc false
  # A round top for the scale: the largest value, or `max` when given, raised
  # to 1, 2 or 5 times a power of ten. A chart of nothing still has a scale.
  def scale_top(_values, max) when is_number(max), do: max

  def scale_top(values, nil) do
    case values |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end) do
      largest when largest <= 0 -> 1
      largest -> nice(largest)
    end
  end

  defp nice(value) do
    magnitude = :math.pow(10, :math.floor(:math.log10(value)))

    step =
      Enum.find([1, 2, 5, 10], fn m -> value <= m * magnitude end)

    rounded = step * magnitude
    if rounded == trunc(rounded), do: trunc(rounded), else: rounded
  end

  @doc false
  # The SVG shapes for `values` on a 0..top scale: polylines split at gaps
  # (and a dot for a value with no neighbour), or one bar per value.
  def shapes(:line, values, top) do
    n = length(values)
    step = if n > 1, do: (@right - @left) / (n - 1), else: 0

    values
    |> Enum.with_index()
    |> Enum.chunk_by(fn {value, _i} -> is_nil(value) end)
    |> Enum.reject(fn [{value, _i} | _] -> is_nil(value) end)
    |> Enum.map(fn
      [{value, i}] ->
        {:dot, coord(@left + i * step), coord(y(value, top))}

      run ->
        {:line,
         Enum.map_join(run, " ", fn {v, i} -> "#{coord(@left + i * step)},#{coord(y(v, top))}" end)}
    end)
  end

  def shapes(:bars, values, top) do
    n = max(length(values), 1)
    slot = (@right - @left) / n
    width = max(slot - 1, 0.5)

    for {value, i} <- Enum.with_index(values), is_number(value), value > 0 do
      y = y(value, top)
      {:bar, coord(@left + i * slot + 0.5), coord(y), coord(width), coord(@bottom - y)}
    end
  end

  defp y(value, top), do: @bottom - min(value / top, 1) * (@bottom - @top)

  defp coord(n), do: :erlang.float_to_binary(n / 1, decimals: 1)

  @doc "A count, shortened: 950, 1.2k, 3.4M."
  def short_number(n) when is_integer(n) and n < 1_000, do: Integer.to_string(n)
  def short_number(n) when is_float(n) and n < 1_000, do: :erlang.float_to_binary(n, decimals: 1)

  def short_number(n) when n < 1_000_000,
    do: :erlang.float_to_binary(n / 1_000, decimals: 1) <> "k"

  def short_number(n), do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> "M"
end
