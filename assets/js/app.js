// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/openresults"
import topbar from "../vendor/topbar"

// Loaded by the LiveView pages only: the hall display (`OpenResultsWeb.HallLive`,
// root layout `hall_root.html.heex`) and the live boards (`BoardsLive` and
// `GameLive`, root layout `live_root.html.heex`). Every other public page
// ships no bundle.
//
// No CSRF token: the public side has no session for one to be checked
// against, and the socket is declared without session connect-info for
// exactly that reason (see `OpenResultsWeb.Endpoint`). A page that does carry
// the meta tag still sends it.
// The piece set a viewer picked on a live-board page (`openresults:pieces`),
// sent with the connection so the page draws it from the first patch on. The
// server only accepts names of sets it ships; anything else is ignored.
function storedPieces() {
  try {
    const set = localStorage.getItem("openresults:pieces")
    return /^[a-z]{1,20}$/.test(set || "") ? {pieces: set} : {}
  } catch (_) {
    return {}
  }
}

const csrfMeta = document.querySelector("meta[name='csrf-token']")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {
    ...(csrfMeta ? {_csrf_token: csrfMeta.getAttribute("content")} : {}),
    ...storedPieces(),
  },
  hooks: {...colocatedHooks},
})

// The live-board pages use the site's own themes, saved by the same picker
// the static pages carry (`openresults:theme`). They have no inline script, so
// the saved choice is applied here, as soon as this bundle runs.
//
// "No choice yet" is left as the server wrote it: paper. `system` is the
// absence of `data-theme`, as in the stylesheet.
const applyStoredTheme = () => {
  const root = document.documentElement
  if (root.dataset.liveShell !== "1") return

  // What the theme picker's CSS waits for (`html.has-js`): the picker is a
  // control that needs this script, so it stays hidden until the script ran.
  root.classList.add("has-js")

  let saved = null
  try { saved = localStorage.getItem("openresults:theme") } catch (_) { return }
  if (!saved) return

  if (saved === "system") {
    root.removeAttribute("data-theme")
    root.setAttribute("data-theme-source", "system")
  } else {
    root.setAttribute("data-theme", saved)
    root.setAttribute("data-theme-source", "user")
  }
}
applyStoredTheme()

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

