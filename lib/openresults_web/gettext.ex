defmodule OpenResultsWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://gettext.hexdocs.pm), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: OpenResultsWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://gettext.hexdocs.pm) for detailed usage.

  Deliberately identical to the arbiter's app's own backend
  (`PairingsEngineWeb.Gettext`), down to the catalogue layout under
  `priv/gettext`, so a term translated in one project can be lifted into the
  other without a second convention to learn.
  """
  use Gettext.Backend, otp_app: :openresults
end
