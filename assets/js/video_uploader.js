// Video transfers of the tip and review editors: the LiveView external
// uploader "Tus" and the VideoTransfers hook. The page side is
// TipsWeb.Editor; the rules are "Video upload before publication" in
// docs/design/backend-design.md.
//
// The page's preflight reserves or resumes a Stream upload and returns its
// tus endpoint. The uploader sends the file there in 50 MiB chunks, retrying
// a failed chunk after 1, 3 and 5 s but never after a 4xx. Each transfer
// lives in a map by media id with its File, outside LiveView: a reconnect
// cancels the upload entry and clears the file input, but the transfer goes
// on. The entry hears progress only while it is current. Browser progress
// never declares readiness; the page reads that from Stream.
//
// The hook sits on the attachment list. It paints each video slot's
// transfer from the map after every patch and reconnect, and hides the
// page's "Upload interrupted" note while the map holds the transfer. Its
// Resume reopens the file input, so the page resumes the same reservation
// from the reselected file. A transfer that failed after its retries offers
// a Resume that restarts it from the map's File. editor:abort_video (Remove)
// and leaving the page abort transfers; nothing else does.

import {Upload} from "../vendor/tus.js"

const CHUNK_SIZE = 52_428_800
const RETRY_DELAYS = [1000, 3000, 5000]

// media id (string) -> {upload, name, percent, state: "live" | "done" | "interrupted" | "failed"}
const transfers = new Map()

const status = (error) => error?.originalResponse?.getStatus() ?? 0
const clientError = (error) => status(error) >= 400 && status(error) < 500

export function tusUploader(entries, onViewError) {
  for (const entry of entries) {
    const id = String(entry.meta.media_id)
    let detached = false
    // A reconnect starts another page; this entry belongs to the old one.
    onViewError(() => (detached = true))
    const forward = (callback) => !detached && !entry.isCancelled() && callback()

    transfers.get(id)?.upload.abort()

    const transfer = {name: entry.file.name, percent: 0, state: "live"}

    transfer.upload = new Upload(entry.file, {
      uploadUrl: entry.meta.upload_url,
      chunkSize: CHUNK_SIZE,
      retryDelays: RETRY_DELAYS,
      storeFingerprintForResuming: false,
      onShouldRetry: (error) => !clientError(error),
      onProgress: (sent, total) => {
        // 100 is sent once, on success.
        transfer.percent = Math.min(99, Math.floor((sent / total) * 100))
        forward(() => entry.progress(transfer.percent))
        paint(id)
      },
      onSuccess: () => {
        Object.assign(transfer, {percent: 100, state: "done"})
        forward(() => entry.progress(100))
        paint(id)
      },
      onError: (error) => {
        // Stream refused the transfer: restarting cannot help.
        transfer.state = clientError(error) ? "failed" : "interrupted"
        if (transfer.state === "failed") forward(() => entry.error(`tus ${status(error)}`))
        paint(id)
      },
    })

    transfers.set(id, transfer)
    transfer.upload.start()
  }
}

function abort(id) {
  transfers.get(id)?.upload.abort()
  transfers.delete(id)
}

function restart(id) {
  const transfer = transfers.get(id)
  if (transfer?.state !== "interrupted") return
  transfer.state = "live"
  transfer.upload.start()
  paint(id)
}

function paint(id) {
  const slot = document.querySelector(`li[data-media-id="${id}"]`)
  if (!slot) return
  const transfer = transfers.get(id)

  for (const el of slot.querySelectorAll("[data-video-interrupted], [data-video-resume]")) {
    el.hidden = transfer !== undefined
  }

  const span = slot.querySelector("[data-video-transfer]")
  if (!span) return
  span.replaceChildren(...(transfer ? transferNodes(id, transfer) : []))
}

function transferNodes(id, {name, percent, state}) {
  switch (state) {
    case "live":
      return [`Uploading ${name} · ${percent}%`]
    case "done":
      return [`Uploaded ${name}`]
    case "interrupted": {
      const button = document.createElement("button")
      button.type = "button"
      button.dataset.videoRestart = id
      button.className = "ml-2 underline"
      button.textContent = "Resume"
      return ["Upload interrupted.", button]
    }
    case "failed":
      return [`${name} couldn't be uploaded.`]
  }
}

function paintAll(el) {
  for (const slot of el.querySelectorAll("li[data-media-id]")) paint(slot.dataset.mediaId)
}

export const VideoTransfers = {
  mounted() {
    this.handleEvent("editor:abort_video", ({media_id}) => abort(String(media_id)))

    this.el.addEventListener("click", (event) => {
      const resume = event.target.closest("[data-video-resume]")
      const restarted = event.target.closest("[data-video-restart]")
      if (resume) this.el.closest("form").querySelector('input[type="file"][name="videos"]').click()
      if (restarted) restart(restarted.dataset.videoRestart)
    })

    paintAll(this.el)
  },
  updated() {
    paintAll(this.el)
  },
  reconnected() {
    paintAll(this.el)
  },
  // Leaving the page; a reconnect keeps the list.
  destroyed() {
    for (const id of [...transfers.keys()]) abort(id)
  },
}
