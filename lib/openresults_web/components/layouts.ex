defmodule OpenResultsWeb.Layouts do
  @moduledoc """
  The one layout this app has.

  The scaffold's `app/1` wrapper, its flash group and its theme toggle are
  gone. Flash needs a session, which the read path does not fetch, and the
  theme toggle needs JavaScript to remember a choice - the stylesheet honours
  `prefers-color-scheme` instead, which the phone has already decided.
  """
  use OpenResultsWeb, :html

  embed_templates "layouts/*"
end
