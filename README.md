# vim-dadbod-ssh

[![Project Status: Active - The project has reached a stable, usable state and is being actively developed.](http://www.repostatus.org/badges/latest/active.svg)](http://www.repostatus.org/#active)

**NeoVim** plugin that allows [vim-dadbod](https://github.com/tpope/vim-dadbod)
connections to remote servers through ssh.

It's actually a wrapper for existing adapters. It creates ssh tunnel using
`ssh -L ...` and then passing changed connection url to proper adapter.

It was tested with `mysql`, I'm not sure how well it works with other
connections, if you are using it with other db please let me know.


## Requirements

  - **NeoVim** - Plugin is using nvim's `jobstart()` API to create and keep
    tunnel, I'm sure it can be done for Vim 8+ as well. I would be grateful
    for PR :heart:
  - **Linux** or **MacOS** - adapter is using `ssh` command to connect to
    the remote server. It is also using following commands:
    `netstat` (Linux), `lsof` (MacOS), `grep`, `awk` and `sed`. To be more specific this command is
    used:
    `netstat -tuplen 2>/dev/null | grep {localhost} | awk '{print $4}' | sed 's/.*://g'` (Linux)
    `lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep {localhost} | awk '{print $9}' | sed 's/.*://g'` (MacOS)

## Installation

Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'tpope/vim-dadbod'

Plug 'pbogut/vim-dadbod-ssh'
```

Or use your favourite method / package manager.

## Configuration

Adapter format is quite simple, here is example for `mysql` connection:

```vim
let g:my_db = "ssh://sshremotehost:mysql://user:password@databasehost/db_name"
```

Do not use `DB g:my_db = "ssh://.....` especially in your start-up scripts, as
this command will create tunnel (which may take couple seconds) and assign
modified URL to the `g:my_db` variable (see how it works section), which will
work for some time but will fail if tunnel breaks and new one will have to be
established.

As you can see normal connection URL is prepended with `ssh://sshremotehost:`

How to set up SSH password? Please, use public key.
How to set up user and port? You can do this in your `$HOME/.ssh/config`:

```
Host mydbhost-name
  User username
  HostName 123.123.123.123
  Port 22222
```

With that you can use `ssh://mydbhost-name:` in your connection string.


To work adapter don't need any additional configuration, but there are few
things one may want to adjust.


  - `g:db_adapter_ssh_localhost` - defaults to `127.0.0.1`
     Why IP and not just `localhost`? It is used to replace your connection host
     and `localhost` is causing issues with `mysql` (maybe others too?). When
     host is `localhost` `mysql` is trying to connect with socket instead of
     network.
  - `g:db_adapter_ssh_timeout` - defaults to `10000` (10 seconds)
     It's how long adapter will wait for tunnel to be established.
  - `g:db_adapter_ssh_port_range` - defaults to `range(7000, 7100)`
     It's range of local ports that will be used to create tunnels, you can
     specific different range. Script is checking if port is available before
     trying to create tunnel, so if some IPs in range are taken that should be
     fine.

## So how it works?

On first connection `ssh` is used to create tunnel to the remote server. Then
in connection URL port and host are changed to use `localhost` and port that was
used to create tunnel. URL modified like that is then passed to the adapter.

With this URL `ssh://sshremotehost:mysql://user:password@databasehost/db_name`
adapter will run: `ssh -L 7000:databasehost:3306 -t echo ssh_connected; read`.
URL is modified to `mysql://user:password@127.0.0.1:7000/db_name` and that is
passed to the `mysql` adapter.

`read` is used to keep connection alive and `echo` to confirm when connection is
established. `-N` could be used instead `read` but then would have to find
another method to confirm connection was established. If you have better ideas
I accept PR's.

## Contributions

Always welcome.

## License

MIT License;
The software is provided "as is", without warranty of any kind.
