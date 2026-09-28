export function DocPage() {
  return (
    <article className='lab-doc'>
      <h1>Nightly backups with restic</h1>
      <p className='lab-doc-dateline'>
        2026-03-04 — Running on the office file server.
      </p>

      <h2>Summary</h2>
      <p>
        Backups now run nightly with restic, replacing the previous rsync
        mirror. The key fix was one flag:
      </p>

      <div className='lab-doc-figure'>
        <pre><code>restic backup --one-file-system /srv</code></pre>
      </div>

      <p>
        The root cause was <code>/srv/cache</code>{' '}
        — a bind mount of a scratch volume that the old mirror followed into.
        Without the flag, every run re-read the scratch volume and the
        repository grew by its full size each night.
      </p>

      <div className='lab-doc-callout'>
        This document surface keeps the “breathing room” direction: a narrow
        reading measure, generous section rhythm, and quiet figures instead of
        card chrome.
      </div>

      <h3>Why restic over rsync</h3>
      <p>
        A mirror only keeps the latest state. Restic keeps deduplicated,
        encrypted snapshots — enabling point-in-time restores, retention
        policies, and offsite copies without a second full copy.
      </p>

      <h2>Production setup</h2>
      <h3>Files</h3>
      <div className='lab-doc-table-wrap'>
        <table className='lab-doc-table'>
          <thead>
            <tr>
              <th>Path</th>
              <th>Purpose</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>
                <code>/etc/restic/env</code>
              </td>
              <td>Repository location and password file</td>
            </tr>
            <tr>
              <td>
                <code>/etc/restic/excludes.txt</code>
              </td>
              <td>Paths every run skips</td>
            </tr>
            <tr>
              <td>
                <code>/etc/systemd/system/restic.service</code>
              </td>
              <td>One backup and prune run</td>
            </tr>
            <tr>
              <td>
                <code>/etc/systemd/system/restic.timer</code>
              </td>
              <td>Nightly schedule</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3>How it works</h3>
      <div className='lab-doc-figure'>
        <pre><code>{`File server                  Object storage
    │                              │
    │  restic backup               │
    ├─────────────────────────────►│ store new chunks only
    │◄─────────────────────────────┤ returns snapshot id
    │                              │
    │  restic forget --prune       │
    ├─────────────────────────────►│ drop expired snapshots
    │                              │ repack → reclaim space
    │◄─────────────────────────────┤`}</code></pre>
      </div>

      <h2>
        The <code>--one-file-system</code> gap
      </h2>
      <p>
        Without{' '}
        <code>--one-file-system</code>, restic crosses into every mount below
        the backup root. For a scratch volume that changes completely every day,
        each run chunks fresh data and deduplication saves nothing.
      </p>

      <div className='lab-doc-figure'>
        <pre><code>restic backup --one-file-system --exclude-file=/etc/restic/excludes.txt /srv</code></pre>
      </div>
    </article>
  )
}
