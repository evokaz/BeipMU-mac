# Atlas mapping guide

## Open and save maps

Open **View → Atlas Map…** to show Atlas for the active session. Atlas can be
docked in the workspace or used as a separate window. Use **Open** to load an
existing `.atlas` file, or add a map and rooms to start a new one. Use **Save**
or **Save As** after editing; Atlas files can contain multiple maps as well as
rooms, exits, labels, shapes, images, and palette settings.

## Set the current room

Atlas needs a current room before it can follow exits or use most navigation
features. The current room appears in the status bar and is highlighted on the
map. Establish it in one of these ways:

- Select **Locate**, then click the room you are in.
- Enter `/map_guesslocation` to search recent session output for a known room
  name. This is a manual, broad scrollback search; check the result if the same
  room name can appear in descriptions or exit listings.
- If the server sends GMCP `Room.Info`, keep Atlas open. Structured room data
  creates or updates rooms, exits, and the current location automatically.
- When building an empty map, the first room created with the room tool becomes
  the current room.

Use **Center current room** to bring the marker back into view. `/map_look`
prints the current room and its known outgoing commands in the session output.

## Follow movement with Live track

Enable **Live track** after setting the current room. For each server output
line, Atlas checks only rooms connected directly to the current room. The
marker moves when the complete line matches one of those destination room
titles. Matching ignores case, diacritics, repeated whitespace, and an optional
trailing MUCK database reference such as `(#1234R)`.

Live track deliberately does not match a room name embedded in a sentence or
an exit listing. For example, `Obvious exits: Town Square, East Road` does not
move the marker, while a line containing only `East Road` can. If a server
decorates room titles in another way, use **Locate** or `/map_guesslocation` to
correct the position.

Live track changes location only. It does not create rooms or exits, and typing
a movement command does not move the marker in advance. GMCP `Room.Info` is
separate from Live track: when Atlas is open, structured room updates are
applied even if Live track is off.

## Use exits and routes

The **Known exits** menu lists commands from the current room. Choosing one
sends that command to the server.

- **Path:** Click a destination to highlight the shortest known route. Click
  the same destination again to send the next command and advance through the
  route one step at a time.
- **Run:** Click a destination to send every command in the shortest known
  route.
- **Find Rooms:** Enter part of a room name and press Return repeatedly to move
  through matching rooms.

Routes use only exits that have a command in the required direction. If Atlas
cannot find a route, verify the current room and the commands on each exit.

## Add and edit map content

Choose a creation tool, then drag on the canvas. A click without a meaningful
drag creates a default-sized object. With **Create exit**, drag from the source
room to the destination room, then enter the commands for traveling there and
back. The return command is optional. Double-click an object with **Select**,
or use its context menu, to edit its properties. Selection filters can prevent
rooms, exits, or decorative objects from being selected accidentally.

The mapping commands provide a quicker way to extend an existing map:

| Command | Effect |
| --- | --- |
| `/map_addroom "Moonlit Road" north south` | Add a room connected to the current room, with commands for traveling there and back. Quote names or commands that contain spaces. Compass commands influence where the new room is placed; a custom command places it to the right. |
| `/map_addexit east west` | Connect the current room to the nearest existing room in the requested compass direction. The first command must be `n`, `ne`, `e`, `se`, `s`, `sw`, `w`, `nw`, `up`, `down`, or its full spelling. |
| `/map_guesslocation` | Search recent output for the most recent known room name and set it as current. |
| `/map_look` | Print the current room and known exits. |

Both add commands require Atlas to know the current room. `/map_addroom`
creates a new connected room but does not make it current; use **Locate** after
moving into it. Use Undo and Redo for map edits, and save the Atlas file when
finished.

## Automate room creation with an alias and trigger

On a MUX-compatible server, an alias can ask the server to resolve the room at
an exit, and a trigger can pass the response to `/map_addroom`. This avoids
typing every destination room name by hand.

First open **Tools → Aliases**, add an alias, enable **Regular expression**, and
use these values:

```text
Match:       ^map (.+) (.+)$
Replace with: think MAP> Exit: <$1> - Room: <[name(room($1))]> - Return: <$2>
```

The alias keyword is `map`, without a leading slash. BeipMU handles text
beginning with `/` as a client command before aliases are considered. The
replacement is ordinary text sent to the server, so **Process commands in
result** is not required for this alias.

Next open **Tools → Triggers**, add a regular-expression trigger, choose the
**Send text** action, and use:

```text
Match:     ^MAP> Exit: <(.+)> - Room: <(.+)> - Return: <(.+)>
Send text: /map_addroom "$2" "$1" "$3"
```

With Atlas open and its current room set, enter:

```text
map east west
```

The alias sends the `think` expression. The server replies with the exit,
resolved destination name, and return command; the trigger then creates the
room and connects it to the current mapped room. The marker remains in the
source room. After moving through the exit, Live track can recognize the newly
added destination, or you can set it with **Locate**.

The `think` and `[name(room(...))]` expression is server-specific. On another
codebase, replace the alias result with that server's command for evaluating
the destination and sending the tagged `MAP>` response back to yourself. Keep
the response format and trigger captures in sync.

Scope the alias and trigger to the relevant world or character, and use a
distinctive response prefix. A matching server line runs the trigger's local
mapping command, so disable the automation when it is not needed. If the
workflow does not fire, open **Tools → Alias Debugger** and **Tools → Trigger
Debugger** to see whether the input and response matched.
