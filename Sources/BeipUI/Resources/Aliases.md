# Aliases

Aliases transform text before it is sent to a world. A literal alias replaces
each matching occurrence. Regular-expression aliases can use capture
references from 0 through 9 and the two-digit a00 through a99 form; the Mac
editor also accepts the legacy dollar capture form.

Each alias has its own Process Aliases, Echo processed alias, and Process
commands in result settings. The containing scope's Active flag remains the
master switch. Aliases are applied in global pre, world pre, character,
puppet, world post, and global post order. A folder always evaluates its
children; children of an ordinary alias run only after that alias matched.
Stop Processing takes effect after a matched alias's children have completed.

Alias matches may begin with `/`. Slash-prefixed aliases run only when their
command name is not reserved by a built-in BeipMU command; built-in commands
always take precedence, including when their arguments are invalid. Use `//`
to send a literal leading slash to the world.

Use Test String to preview the complete replacement result. Invalid regular
expressions are shown inline and are skipped by the runtime so later aliases
can still run.
