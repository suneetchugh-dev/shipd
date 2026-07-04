' shipd: run a console command with no window (Task Scheduler flashes one otherwise)
Set sh = CreateObject("WScript.Shell")
cmd = ""
For Each a In WScript.Arguments
    cmd = cmd & """" & a & """ "
Next
sh.Run Trim(cmd), 0, True
