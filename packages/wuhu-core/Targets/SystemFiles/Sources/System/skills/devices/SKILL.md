---
name: devices
description: Resolve the person's live device and drive its sidebar only when asked just now.
wuhu_when: {kind: agent}
---

# Devices

A device is an app install a person is signed into: a phone, pad, mac, vision or web client. A message sent from one carries `<device>Name (three-word-id)</device>` in its header, and that id is the handle for everything below. The induced `devices` table (id, name, kind, machine_id, last_seen_at) is queryable and observable; `machine_id` ties a device to the box its owner works on, so "the screenshots on my desktop" resolve to `machines://<machine_id>/...` without asking. Names and the machine link are set with `wuhu device set`, never by the app. `manipulate_ui(device, payload)` drives that device's UI live: the payload reaches the app verbatim, and today it is `{"sidebar": "/.sidebars/<file>"}` (a `.sidebar.jsx` script or a `.json` definition; the `sidebars` skill) or `{"sidebar": "everything"}`. The app drops a command older than 15 seconds, so this is for the person in front of the screen right now.
