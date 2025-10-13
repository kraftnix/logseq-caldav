use std/log;
const PRODID = "-//Logseq Task Syncer v0.0.1"

## Helper Functions

# diff two texts/strings against each other with difftastic
def diffTexts [
  text1 : string # previous text
  text2 : string # new text
] {
  let f1 = $"(mktemp -d)/text1"
  let f2 = $"(mktemp -d)/text2"
  $text1 | save $f1
  $text2 | save $f2
  difft $f1 $f2 --display side-by-side-show-both
  rm -rf $f1 | ignore
  rm -rf $f2 | ignore
}


# Returns true if the key exists and is not an empty string
def nullOrStr [ key: string ]: record -> bool {
  ($in | get -o $key | default "") == ""
}

# Returns the value in the key or an empty string
def getValue [ key : string ]: table -> string {
  where name == $key | get -o value.0 | default ""
}

# Upserts a key/value into the stdin table provided if exists in the table
# in the first parameter
def upsertIfExists [
  lookupTable : any # table to lookup key in (actual type is record|table but can't get nushell to recognise it
  lookupKey   : string # key to lookup
  upsertKey   : string # key to upsert
]: record -> record {
  let upsertTable = ($in)
  let value = ($lookupTable | getValue $lookupKey)
  if $value != "" {
    $upsertTable | upsert $upsertKey $value
  } else {
    $upsertTable
  }
}

## Parsing Functions

# parses a logbook entry
def parseLogbook [ ]: string -> table<start: string, end: string, time: string> {
  lines | str trim | parse "CLOCK: [{start}]--[{end}] => {time}"
}

# Parses the task content provided by the Logseq HTTP API into a description
def parseTaskDescription [ taskContent: string ] {
  # let desc = ($taskContent | lines | take until {|line| (
  #   ($line | str starts-with id::)
  #   or
  #   ($line | str starts-with SCHEDULED:)
  #   or
  #   ($line | str starts-with DEADLINE:)
  #   or
  #   ($line | str starts-with :LOGBOOK:)
  # )} | str join "\n")
  let desc = ($taskContent | lines | take until {|line| (
    [
      "id::"
      "todo::"
      "later::"
      "now::"
      "done::"
      "doing::"
      "created-at::"
      "updated-at::"
      "collapsed::"
      "SCHEDULED:"
      "DEADLINE:"
      ":LOGBOOK:"
    ] | any {|match| $line | str starts-with $match}
  )} | str join "\n")
  let words = ($desc | split words)
  if ($words | length) == 0 {
    print -e $desc
    return ""
  }
  if ($words | first | str trim) in [ "DONE" "LATER" "TODO" "done" "later" "todo"] {
    $words | skip | str join " "
  } else {
    $desc
  }
}

# Formats a date into an ics compatible timestamp
def formatDate [ ]: datetime -> string {
  # format date "%Y%m%dT%H%M%SZ" # UTC
  # format date "%Y%m%dT%H%M%S%Z" # with timezone like +0100
  format date "%Y%m%dT%H%M%S" # timezoneless
}

# Formats a string date with the timezone in $env.LSQ_TIMEZONE_STR
#  - i.e. 20250101T001122 -> TZID=Europe/Berlin:20250101T001122
def formatDateTZ [ ]: string -> string {
  $"TZID=($env.LSQ_TIMEZONE_STR):($in)"
}

# Formats a date into a Logseq Logbook compatible timestamp
def formatIcsDateToLogseq [ ]: datetime -> string {
  format date "%Y-%m-%d %H:%M:%S"
}

# Removes Day name from a timestamp (from Logseq)
def removeDays [ ]: string -> string {
  $in
  | str replace "Mon " ""
  | str replace "Tue " ""
  | str replace "Wed " ""
  | str replace "Thu " ""
  | str replace "Fri " ""
  | str replace "Sat " ""
  | str replace "Sun " ""
}

# Parses a Logseq Logbook date into a formatted date
def parseLogseqDate [ ] {
  # TODO: the different objects here are nasty
  let str = ($in | removeDays)
  if ($str | split chars | length) == 23 {
    $str | parse "{year}-{month}-{day} {hour}:{minute}:{second}" | into datetime | each {date to-timezone $env.LSQ_TIMEZONE}
  } else if ($str | split chars | length) == 20 {
    $str | parse "{year}-{month}-{day} {hour}:{minute}" | into datetime | each {date to-timezone $env.LSQ_TIMEZONE}
  } else {
    # Unknown but try anyway
    try {
      let date = ($str | parse "{year}{month}{day}T{hour}{minute}{second}Z")
      if $date != [] {
        $date | into datetime | each {date to-timezone $env.LSQ_TIMEZONE}
      } else {
        $str | date from-human | each {date to-timezone $env.LSQ_TIMEZONE} | formatDate
      }
    } catch {|err|
      print -e $err
      print -e $"Unable to parse date: ($str)"
    }
  }
}

# Parses a datelike string (20230131)
def parseDayDate [ dayTs: any ]: nothing -> datetime {
  let day = ($dayTs | into string)
  let date = [
    ($day | str substring 0..3)
    ($day | str substring 4..5)
    ($day | str substring 6..7)
  ]
  $"($date | str join "-") 00:00:00" | date from-human | each {date to-timezone $env.LSQ_TIMEZONE}
}

# Attempts to parse any type of integer date
def parseDateAny [ date: int ]: nothing -> datetime {
  # TODO: cleanup different types + handling
  let len = ($date | into string | split chars | length)
  if $date == "UNKNOWN" {
    $date
  } else if $len == 8 {
    $date | parseDayDate $in | date to-timezone $env.LSQ_TIMEZONE
  } else if $len == 13 {
    $date * 1000000 | into datetime | date to-timezone $env.LSQ_TIMEZONE
  } else {
    print -e "UNEXPECTED"
    $date
  }
}

# Sets a created date based on possible existing entries in logseq task returned by HTTP API
def getCreated [ logseqTask : record ]: nothing -> datetime {
  let date = $logseqTask | get -o created-at | default (
    $logseqTask | get -o properties.later | default (
      $logseqTask | get -o page.created-at | default (
        $logseqTask | get -o page.journal-day | default "UNKNOWN"
      )
    )
  )
  parseDateAny $date
}

## Internal Task/Event transform functions

# Transforms an ics event file to an internal Event
def icsToEvent [
  ics : table # contents of an ics file containing a single VEVENT (opened with nushell `open XX.ics`)
]: nothing -> record {
  try {
    let event = ($ics.events.0.properties.0)
    {
      type: "VEVENT"
      version: ($ics.properties.0 | getValue "VERSION")
      prodid: ($ics.properties.0 | getValue "PRODID")
      dtstamp: ($event | getValue "DTSTAMP")
      start: ($event | getValue "DTSTART")
      end: ($event | getValue "DTEND")
      uid: ($event | getValue "UID")
      summary: ($event | getValue "SUMMARY")
      sequence: ($event | getValue "SEQUENCE" | into int)
    }
  } catch {|err|
    print -e $err
    print -e $"Failed to read event ics file with uuid:\n($ics)"
  }
}

# Transforms an ics task file to an internal task
def icsToTask [
  ics : table # content of an ics file containing a single VTODO (opened with nushell `open XX.ics`)
  --noTags    # omit tag parsing
] {
  try {
    let todos = ($ics.to-Dos.0.properties.0)
    mut task = {
      type: "VTODO"
      version: ($ics.properties.0 | getValue "VERSION")
      prodid: ($ics.properties.0 | getValue "PRODID")
      uid: ($todos | getValue "UID")
      created: ($todos | getValue "CREATED")
      last-modified: ($todos | getValue "LAST-MODIFIED")
      summary: ($todos | getValue "SUMMARY")
      logevents: []
      tags: []
    }
    | upsertIfExists $todos "DTSTAMP" "dtstamp"
    | upsertIfExists $todos "DESCRIPTION" "description"
    | upsertIfExists $todos "DUE" "deadline"
    | upsertIfExists $todos "DTSTART" "schedule"
    | upsertIfExists $todos "COMPLETED" "completed"
    | upsertIfExists $todos "CATEGORIES" "tags"
    | update "tags" {|row| $row.tags | split row "," | sort}
    if $ics.events != [] {
      $task.logevents = ($ics.events.0.properties | each {|event|
        {
          type: "VEVENT"
          version: ($ics.properties.0 | getValue "VERSION")
          prodid: ($ics.properties.0 | getValue "PRODID")
          dtstamp: ($event | getValue "DTSTAMP")
          start: ($event | getValue "DTSTART")
          end: ($event | getValue "DTEND")
          uid: ($event | getValue "UID")
          summary: ($event | getValue "SUMMARY")
          sequence: ($event | getValue "SEQUENCE" | into int)
        }
      })
    }
    if $noTags {
      $task = ($task | reject tags)
    }
    $task
  } catch {|err|
    print -e $err
    print -e $"Failed to read ics file with uuid:\n($ics)"
  }
}

# Transforms a Logseq task (from HTTP API) to an internal task
def logseqToTask [
  task : record
  --eventsInTasks(-t) # include events in tasks
]: nothing -> record {
  let schedule = ($task | get -o scheduled | default "")
  let deadline = ($task | get -o deadline | default "")
  let textOnly = (parseTaskDescription $task.content | lines)
  let description = ($textOnly | skip | str join "\n" | str trim)
  let summary = ($textOnly | first | str trim)
  let logevents = ($task.logbook
    | where {|i| # filter out unfinished logs
      ($i | get -o end | default "") != ""
    }
    | enumerate
    | each {|i|
      let log = $i.item
      let index = $i.index + 1
      try {
        let dtstamp = (getCreated $task | formatDate)
        let start = ($log.start | parseLogseqDate)
        let end = ($log.end | parseLogseqDate)
        {
          type: "VEVENT"
          version: "2.0"
          prodid: $PRODID
          dtstamp: $dtstamp
          start: $start
          end: $end
          uid: $"($task.uuid)-($index)"
          summary: $"($summary) (($index | into string))"
          sequence: 1
        }
      } catch {|err|
        print -e $err
        print -e $"Failed to parse dates in log ($i.index | into string) for task ($task.uuid)"
      }
    }
  )
  mut caldav = {
    type: "VTODO"
    version: "2.0"
    prodid: $PRODID
    uid: $task.uuid
    created: (getCreated $task | formatDate)
    last-modified: (date now | formatDate)
    dtstamp: (getCreated $task | formatDate)
    summary: $summary
    logevents: $logevents
    tags: (
      $task.refs
      | where {|ref|
        not (
          [
            "DONE"
            "DOING"
            "LATER"
            "CANCELLED"
            "TODO"
            "NOW"
            "A"
            "B"
            "C"
          ] | any {$in == ($ref | get -o original-name | default "")}
        )
      }
      | each {|tag|
        $tag
        | get -o alias.0.original-name
        | default ($tag | get -o original-name | default "")
        | str replace "," ";" # commas in tags/pages cause issues with tag parsing in ics
        | str trim
      }
      | where {|x| $x != ""}
      | sort
    )
  }
  if $task.marker == "DONE" or $task.marker == "CANCELLED" {
    # set a preliminary completion date for tasks
    $caldav.completed = $caldav.created
    if ($task.logbook | length) != 0 {
      let lastLog = ($task.logbook | last)
      $caldav.completed = ($lastLog | get end | parseLogseqDate)
    }
  }
  if $schedule != "" {
    $caldav.schedule = ($schedule | parseDayDate $in | formatDate)
  }
  if $deadline != "" {
    $caldav.deadline = ($deadline | parseDayDate $in | formatDate)
  }
  if $description != "" {
    $caldav.description = ($description)
  }
  $caldav
}

# Transforms an internal log entry to a VEVENT substring
def logToIcsEventSub [ ]: record<dtstamp: string, start: string, end: string, uid: string, sequence: int, summary: string> -> string {
  let log = $in
  $'
BEGIN:VEVENT
DTSTAMP;($log.dtstamp | formatDateTZ)
DTSTART;($log.start | formatDateTZ)
DTEND;($log.end | formatDateTZ)
UID:($log.uid)
SEQUENCE:($log.sequence)
SUMMARY:($log.summary)
END:VEVENT
  ' | str trim
}

# Transforms an internal log entry to an .ics string with a single VEVENT
def logToIcsEvent [ log ]: record<dtstamp: string, start: string, end: string, uid: string, sequence: int, summary: string> -> string {
  $'
BEGIN:VCALENDAR
VERSION:2.0
PRODID:($PRODID)
($log | logToIcsEventSub)
END:VCALENDAR
  ' | str trim
}

# Transforms an internal task object and generates an .ics string with a single VTODO
#
# DTSTAMP: UTC time that the scheduling message was generated (required by iCal)
# SUMMARY: title
# DTSTART: start time (optional)
# DUE: due time (optional)
# DESCRIPTION: description (optional)
# PERCENT-COMPLETE: (optional)
# COMPLETED: completed time (optional)
def taskToIcsTodo [
  caldav
  --noTags # do not write tags as categories
  --noEvents # do no write events
] {
  let hasSchedule = not ($caldav | nullOrStr "schedule")
  let hasDeadline = not ($caldav | nullOrStr "deadline")
  [
$'
BEGIN:VCALENDAR
VERSION:2.0
PRODID:($caldav.prodid)
BEGIN:VTODO
UID:($caldav.uid)
CREATED;($caldav.created | formatDateTZ)
LAST-MODIFIED;($caldav.last-modified | formatDateTZ)
DTSTAMP;($caldav.dtstamp | formatDateTZ)
SUMMARY:($caldav.summary)
'
(if ($caldav.tags != []) and (not $noTags) { $'CATEGORIES:($caldav.tags | str join ",")' } else { [] })
( # TODO: refactor / deduplicate
  # some special handling is required because DUE cannot be before DTSTART...
  if $hasSchedule and $hasDeadline {
    if ($caldav.deadline | into datetime) < ($caldav.schedule | into datetime) {
      # we simply don't bother with due date in this case... maybe better behaviour could be done.
      $"DTSTART;($caldav.schedule | formatDateTZ)"
    } else {[
      $"DTSTART;($caldav.schedule | formatDateTZ)"
      $"DUE;($caldav.deadline | formatDateTZ)"
    ]}
  } else if $hasSchedule {
    $"DTSTART;($caldav.schedule | formatDateTZ)"
  } else if $hasDeadline {
    $"DUE;($caldav.deadline | formatDateTZ)"
  } else {
    []
  }
)
(if ($caldav | nullOrStr "description") { [] } else { $"DESCRIPTION:($caldav.description)" })
(if ($caldav | nullOrStr "completed") { [] } else {
$'
PERCENT-COMPLETE:100
COMPLETED;($caldav.completed | formatDateTZ)
'
})
'END:VTODO'
(if $noEvents or ($caldav.logevents == []) { [] } else {
  $caldav.logevents | each {logToIcsEventSub} | str join "\n"
})
'END:VCALENDAR'
  ] | flatten | str trim | str join "\n"
}

# Queries the Logseq HTTP API for all tasks and parses logbook and task content in descriptions
def getLogsFromApi []: nothing -> string {
  let query = '
    [:find (pull ?b [
      *
      {:block/page [:db/id :block/name :block/journal-day :block/created-at]}
      {:block/refs [:db/id :block/name :block/journal :block/original-name {:block/alias [:block/original-name]}]}
    ])
    :where
      [?b :block/marker ?marker]
      [(contains? #{"TODO","DOING","LATER","DONE","CANCELLED"} ?marker)]
      [?b :block/page ?page]
    ]
  '
  queryHttp $query
    | flatten
    | each {|task|
      # {...$task, logbook: ($task.content | parseLogbook)}
      {...$task, logbook: ($task.content | parseLogbook), description: (parseTaskDescription $task.content)}
    } | to json
}

## Main

# Queries the Logseq HTTP API with a provided query, returns a list of JSON strings
#
# a query like:
# [
#   :find (pull ?h [*])
#   :where
#     [?h :block/marker ?marker]
#     [(= ?marker "TODO")]]
# ]
def queryHttp [ query: string ]: nothing -> table {
  {
    method: "logseq.DB.datascriptQuery",
    args: [ $query ]
  } | to json
    | (http post $env.LSQ_HTTP_ENDPOINT
        --content-type application/json
        --headers {
          Authorization: $"Bearer ($env.LSQ_HTTP_BASIC_AUTH)"
        }
      )
}

# Queries the Logseq tasks from it's HTTP API and generates a directory of .ics files.
#
# Most configuration for this script is done via environment variables:
#  - `LSQ_HTTP_BASIC_AUTH`: Password of valid Logseq Authorization Token (required)
#  - `LSQ_HTTP_ENDPOINT`: Location of Logseq HTTP API endpoint (default: "localhost:12315/api")
#  - `LSQ_TASK_DIR`: Directory where tasks will be written (required) (example: "~/.local/state/calendars/nextcloud/logseq")
#  - `LSQ_EVENT_DIR`: Directory where events will be written (required) (defaults to `LSQ_TASK_DIR`) (example: "~/.local/state/calendars/nextcloud/logseq")
def parseAndWriteTasks [
  --noTags(-t)        # include tags in tasks
  --eventsInTasks(-e) # include events in tasks
] {
# Check if ENV is correctly set
  if ($env | get -o LSQ_TASK_DIR) == null {
    print -e "LSQ_TASK_DIR not found in environment, please set it (example: ~/.local/state/calendars/nextcloud/logseq)"
    exit 1
  }
  if ($env | get -o LSQ_HTTP_BASIC_AUTH) == null {
    print -e "LSQ_HTTP_BASIC_AUTH not found in environment, please get an Authorization Token from Logseq and set it"
    exit 1
  }

  $env.LSQ_TIMEZONE = ($env | get -o LSQ_TIMEZONE | default (date now | format date "%z")) # like +0100
  $env.LSQ_TIMEZONE_STR = ($env | get -o LSQ_TIMEZONE_STR | default (timedatectl show -P Timezone | str trim)) # like Europe/Berlin
  $env.LSQ_HTTP_ENDPOINT = ($env | get -o LSQ_HTTP_ENDPOINT | default "localhost:12315/api")
  $env.LSQ_EVENT_DIR = ($env | get -o LSQ_EVENT_DIR | default $env.LSQ_TASK_DIR)

  let noEvents = (not $eventsInTasks)
  getLogsFromApi
  | from json
  | par-each {|logseqTask| {
    # ics: (logseqToTask $task | taskToIcsTodo $in)
    task: (logseqToTask $logseqTask --eventsInTasks=$eventsInTasks)
    icsTask: ($"($env.LSQ_TASK_DIR | into string)/($logseqTask.uuid).ics" | path expand)
  } }
  # TODO: refactor this, lots of repeated code
  | each {|t|
    if $eventsInTasks {
      let pathExists = ($t.icsTask | path exists)
      if $pathExists {
        let oldIcs = (open $t.icsTask | icsToTask $in --noTags=$noTags)
        # check if ics are same except modified date
        if ($oldIcs | reject last-modified) == ($t.task | reject last-modified) {
          log info $"No changes to ics at ($t.icsTask)"
        } else {
          log info $"Updating existing ics to ($t.icsTask)"
          diffTexts ($oldIcs | to json) ($t.task | to json)
          $t.task | taskToIcsTodo $in --noTags=$noTags | save -f $t.icsTask
        }
      } else {
        log info $"Saving new ics to ($t.icsTask)"
        $t.task | taskToIcsTodo $in --noTags=$noTags | save $t.icsTask
      }
    } else {
      let pathExists = ($t.icsTask | path exists)
      $t.task.logevents | each {|log|
        let icsEvent = ($"($env.LSQ_EVENT_DIR)/($log.uid).ics" | path expand)
        let pathExists = ($icsEvent | path exists)
        if $pathExists {
          let oldIcs = (open $icsEvent | icsToEvent $in)
          # check if ics are same except modified date
          if ($oldIcs) == ($log) {
            log info $"No changes to ics event at ($icsEvent)"
          } else {
            log info $"Updating existing ics event to ($icsEvent)"
            # (psub [difft] {echo $oldIcs} {echo $t.task})
            diffTexts ($oldIcs | to json) ($log | to json)
            $log | logToIcsEvent $in | save -f $icsEvent
          }
        } else {
          log info $"Saving new ics event to ($icsEvent)"
          $log | logToIcsEvent $in | save $icsEvent
        }
      }
      # logevents removed for next step
      let $t = {
        icsTask: $t.icsTask
        task: ($t.task | update logevents {|row| []})
      }
      if $pathExists {
        let oldIcs = (open $t.icsTask | icsToTask $in --noTags=$noTags)
        # check if ics are same except modified date
        if ($oldIcs | reject last-modified) == ($t.task | reject last-modified) {
          log info $"No changes to ics at ($t.icsTask)"
        } else {
          log info $"Updating existing ics to ($t.icsTask)"
          # (psub [difft] {echo $oldIcs} {echo $t.task})
          diffTexts ($oldIcs | to json) ($t.task | to json)
          $t.task | taskToIcsTodo $in --noTags=$noTags --noEvents=$noEvents | save -f $t.icsTask
        }
      } else {
        log info $"Saving new ics to ($t.icsTask)"
        $t.task | taskToIcsTodo $in --noTags=$noTags --noEvents=$noEvents | save $t.icsTask
      }
    }
  }
}

# Queries the Logseq tasks from it's HTTP API and generates a directory of .ics files.
#  - Optionally also run vdirsyncer (--sync)
#  - Optionally run entire script on a periodic basis (--period=1min)
#
# Most configuration for this script is done via environment variables:
#  - `LSQ_HTTP_BASIC_AUTH`: Password of valid Logseq Authorization Token (required)
#  - `LSQ_HTTP_ENDPOINT`: Location of Logseq HTTP API endpoint (default: "localhost:12315/api")
#  - `LSQ_TASK_DIR`: Directory where tasks will be written (required) (example: "~/.local/state/calendars/nextcloud/logseq")
#  - `LSQ_EVENT_DIR`: Directory where events will be written (required) (defaults to `LSQ_TASK_DIR`) (example: "~/.local/state/calendars/nextcloud/logseq")
#  - `LSQ_VDIRSYNCER_CALENDAR`: `vdirsyncer` calendar to sync if sync enabled
#                             can be a base calendar (nextcloud_calendars) or a specific (nextcloud_calendars/logseq)
#                             it is recommended to use a specific calendar over a base to not force sync other non-logseq calendars.
def main [
  --sync(-s)            # runs a vdirsync after generating ics files
  --period(-p) : string # duration of time between repeating this script, takes a string parseable as a nushell duration (example: "1min")
  --noTags(-t)          # include tags in tasks
  --eventsInTasks(-e)   # include events in tasks
] {
  loop {
    parseAndWriteTasks --noTags=$noTags --eventsInTasks=$eventsInTasks
    if $sync {
      log info $"Running sync to ($env.LSQ_VDIRSYNCER_CALENDAR)"
      vdirsyncer sync $env.LSQ_VDIRSYNCER_CALENDAR
    }
    if $period == null {
      exit 0
    } else {
      log info $"Sleeping for ($period)"
      sleep ($period | into duration)
    }
  }
}

## DEBUG / WIP
def randomQueryies [ ] {
  # filtered down query
  let query = '
    [:find (pull ?b [{:block/page [:page/created-at :page/id]}])
    :where
      [?b :block/marker ?marker]
      [(= ?marker "DONE")]
      [?p :block/page ?page]
    ]
  '

  # basic query
  let pages = '
    [:find (pull ?page [*])
    :where
      [?b :block/marker ?marker]
      [(= ?marker "DONE")]
      [?b :block/page ?page]
    ]
  '

  # get page references where task exists
  let query = '
    [:find (pull ?b [
      *
      {:block/page [:db/id :block/name :block/journal-day :block/created-at]}
    ])
    :where
      [?b :block/marker ?marker]
      [(= ?marker "DONE")]
      [?b :block/page ?page]
    ]
  '
  # get page references where task exists
  # get related tags + resolve their aliases
  let query = '
    [:find (pull ?b [
      *
      {:block/page [:db/id :block/name :block/journal-day :block/created-at]}
      {:block/refs [:db/id :block/name :block/original-name {:block/alias [:block/original-name]}]}
    ])
    :where
      [?b :block/marker ?marker]
      [(contains? #{"TODO","DOING","LATER","DONE","CANCELLED"} ?marker)]
      [?b :block/page ?page]
    ]
  '
  queryHttp $query
}
