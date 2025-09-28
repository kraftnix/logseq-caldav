# Logseq Caldev

Logseq Caldev is a tool to generate CalDAV Tasks and Calendar events from Logseq Tasks using Logseq's HTTP API.

The tool generates iCalendar ics files in a directory, which can then be synced to CalDAV using tools like [vdirsyncer](https://github.com/pimutils/vdirsyncer).

Two-way sync is not currently supported, any modifications made to the specified CalDAV endpoints via
other apps will be overridden whenever the sync is run.

## Requirements

  - a CalDAV server
  - an accessible Logseq HTTP API endpoint
  - a tool which can sync a directory of `.ics` files to a CalDAV server

## Tested Tools

  - Nextcloud Calendar (created with task support)
  - [vdirsyncer](https://github.com/pimutils/vdirsyncer)

## Setup

A fully functional sync [requires](#Requirements) a few services to be setup.

### Logseq

Open Logseq and enable the HTTP API Endpoint.

Setup an Authorized Token, copy the token name and password for later use.

### Nextcloud Calendar

Go to the Nextcloud Calendar app and create a Calendar with tasks support (`New calendar with tasks list`).

You may want to also want to create a Nextcloud App Password for `vdirsyncer` usage via the WebUI under (Settings -> Security -> Devices & Sessions -> App Name/Password).

### Vdirsyncer

Create a vdirsyncer config at `~/.config/vdirsyncer/config` like:

```ini
[general]
status_path = "~/.local/state/vdirsyncer"

[pair nextcloud_calendars]
a = "nextcloud_calendars_local"
b = "nextcloud_calendars_remote"
collections = ["from a", "from b"]
metadata = ["color"]
conflict_resolution = "a wins"

[storage nextcloud_calendars_local]
type = "filesystem"
path = "~/.local/state/calendars/nextcloud/"
fileext = ".ics"

[storage nextcloud_calendars_remote]
type = "caldav"
url = "https://nextcloud.mydomain.com/remote.php/caldav/"
username = "myuser"
password = "XXXX-XXXX-XXXX"
```

Discover Calendars
```sh
vdirsyncer discover nextcloud_calendars
```

This will create the needed directories at `~/.local/state/calendars/nextcloud` (or otherwise specified in your local calendar storage).

## Usage

There are two environment variables required to run the sync:

```sh
export LSQ_HTTP_BASIC_AUTH = "myLogseqAuthorizationToken"
export LSQ_TASK_DIR = "~/.local/state/calendars/nextcloud/logseq"
export LSQ_EVENT_DIR = "~/.local/state/calendars/nextcloud/logseq" # this is LSQ_TASK_DIR if not set
```

To parse logseq tasks and write to the event/task directories:

```sh
# run with nix
nix run github:kraftnix/logseq-caldav

# or add to shell
nix shell github:kraftnix/logseq-caldav
logseq-caldav

# or from root of repo
nu logseq-caldav.nu
```

Optionally run a vdirsyncer sync:
```sh
export LSQ_VDIRSYNCER_CALENDAR = "nextcloud_calendars/logseq"
logseq-caldav --sync
```

You can make the script run periodically:
```sh
logseq-caldav --sync --period 30min
```

### Client Notes

- Davx5 on Android should set the logseq calendar to readonly to reduce churn of events/tasks (rewriting of PRODID in tasks)

## Implementation Notes

- Task and Event titles and descriptions (at least in testing with Nextcloud Calendar + vdirsyncer) seem to sanitise the input:
  - ids like `((60def7c5-9561-5ec4-b17b-e74c091df1d7))` are transformed to `60def7c5 9561 5ec4 b17b e74c091df1d7`
  - pages/tags like `[[MyPage]]` are transformed to `MyPage`
- All CalDAV events generated via the `parse_tasks.nu` script are overwritten on each use, so your CalDAV sync tool (like vdirsyncer)
  must either overwrite external changes or you must handle the sync conflicts yourself.
- The script will not perform any writes on `.ics` files which have not changed (the `Last-Modified` field in VTODO is not checked when performing the equality check)
- The tool makes a best attempt to split multiline Logseq tasks into a separate Summary and Description, where the Summary is the first line (without LATER/DONE)
  and the description is any other line afterwards.
- Using a CalDAV server without support for combined Calendars and Tasks is supported, but you must choose two separate directories
  (and therefore calendars) to sync the ics files to, by default `LSQ_EVENT_DIR` uses the same value as `LSQ_TASK_DIR`,
  this is an assumption that the same CalDAV directory can be used for both tasks (VTODO) and calendar events (VEVENT).
