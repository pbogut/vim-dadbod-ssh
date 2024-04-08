if exists('g:autoloaded_db_ssh')
  finish
endif

let g:autoloaded_db_ssh = 1
let s:localhost = get(g:, 'db_adapter_ssh_localhost', '127.0.0.1')
let s:timeout = get(g:, 'db_adapter_ssh_timeout', 10000)
let s:port_range = get(g:, 'db_adapter_ssh_port_range', range(7000, 7100))

let s:tunnels = {}
let s:wait_list = {}
let s:default_ports = {
      \   'mariadb': 3306,
      \   'mysql': 3306,
      \   'postgresql': 5432,
      \   'sqlserver': 1433,
      \   'presto': 8080,
      \   'oracle': 1521,
      \   'mongodb': 27017,
      \ }

" experimental, when true play nicer with DBUI (but worse with DB)
let s:default_async = get(g:, 'db_ssh_default_async', v:false)

function s:get_free_port()
  let env = toupper(substitute(system('uname'), '\n', '', ''))

  let detect_open_port_cmd = env =~ 'DARWIN'
      \ ? ("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep " . s:localhost . " | awk '{print $9}' | sed 's/.*://g'")
      \ : ("netstat -tuplen 2>/dev/null | grep " . s:localhost . " | awk '{print $4}' | sed 's/.*://g'")

  let ports = systemlist(detect_open_port_cmd)

  for port in s:port_range
    call add(s:port_range, port)
    call remove(s:port_range, 0)
    if index(ports, "" . port) == -1
        return port
    endif
  endfor

  return 0
endfunction

call s:get_free_port()

function! s:prefix(url) abort
  let scheme = tolower(matchstr(a:url, '^[^:]\+'))
  let adapter = tr(scheme, '-+.', '_##')
  if empty(adapter)
    throw 'DB: no URL'
  endif
  if exists('g:db_adapter_' . adapter)
    let prefix = g:db_adapter_{adapter}
  else
    let prefix = 'db#adapter#'.adapter.'#'
  endif
  return prefix
endfunction

function! s:fn_name(url, fn) abort
  let url = substitute(a:url, '^[^:]\+', '\=get(g:db_adapters, submatch(0), submatch(0))', '')
  let prefix = s:prefix(url)
  return prefix . a:fn
endfunction

function! s:drop_ssh_part(url) abort
  return substitute(a:url, '^ssh://[^:]*:', '', '')
endfunction

function! s:get_ssh_host(url) abort
  return substitute(a:url, '^ssh://\([^:]*\):.*', '\1', '')
endfunction

function! s:on_event(job_id, data, event) dict
  if a:event == 'stdout'
    let str = self.tunnel_id . ' stdout: '.join(a:data)
    if str =~ 'ssh_connected'
      let s:tunnels[self.tunnel_id] = self.redirect_port
      let s:wait_list[self.tunnel_id] = v:false
      if self.show_connection_info
        echo "Tunnel " . self.tunnel_id . " has been created"
      end
      return
    endif
  elseif a:event == 'stderr'
    let str = self.tunnel_id . ' stderr: '.join(a:data)
    if str =~ 'Pseudo-terminal will not be allocated'
      return
    endif
    if str =~ 'Address already in use'
      call jobstop(a:job_id)
      return
    endif
  else
    let s:wait_list[self.tunnel_id] = v:false
    if (!empty(get(s:tunnels, self.tunnel_id)))
      call remove(s:tunnels, self.tunnel_id)
    endif
    return
  endif
  if len(get(l:, 'str')) > len(self.tunnel_id . ' stdout: ')
    echom str
  endif
endfunction

let s:callbacks = {
      \ 'on_stdout': function('s:on_event'),
      \ 'on_stderr': function('s:on_event'),
      \ 'on_exit': function('s:on_event')
      \ }

function! s:get_tunneled_url(url, ...)
  if a:url !~? '^ssh:'
    return a:url
  endif
  let async = get(a:, 1, s:default_async)

  let ssh_host = s:get_ssh_host(a:url)
  let url = s:drop_ssh_part(a:url)

  let url_parts = db#url#parse(url)
  let scheme = get(url_parts, 'scheme')
  let port = get(url_parts, 'port', get(s:default_ports, scheme))
  let host = get(url_parts, 'host', 'localhost')
  let tunnel_id = ssh_host . ':' . host . ':' . port

  let url_parts['host'] = s:localhost

  let current_port = get(s:tunnels, tunnel_id)
  if (!empty(current_port))
    let url_parts['port'] = current_port
    if async
      echo "Tunnel " . tunnel_id . " already exists"
    endif
    return db#url#format(url_parts)
  endif

  let redirect_port = s:get_free_port()
  if redirect_port == 0
    throw "DB SSH: Can't find free port to use"
  endif

  let url_parts['port'] = redirect_port
  let new_url = db#url#format(url_parts)
  let ssh_redirect = redirect_port . ':' . host . ':' .port

  " check if connection is not currently being made
  if get(s:wait_list, l:tunnel_id, v:false) != v:true
    let s:wait_list[l:tunnel_id] = v:true
    let job = jobstart(['ssh', '-L', ssh_redirect, ssh_host, '-t', 'echo ssh_connected; read'], extend({
          \   'tunnel_id': tunnel_id,
          \   'redirect_port': redirect_port,
          \   'show_connection_info': async,
          \ }, s:callbacks))
  endif

  if async
    echo "Creating tunnel " . tunnel_id . "..."
    return new_url
  end

  " wait for tunnel to be established
  let connection_status = wait(s:timeout, { -> s:wait_list[l:tunnel_id] == v:false }, 100)
  if connection_status == -1
    echom "DB SSH: Timeout while creating tunnel"
  elseif connection_status == -2
    echom "DB SSH: Connection canceled by user"
  elseif connection_status == -3
    echom "DB SSH: Unknown error occured while creating tunnel"
  endif

  return new_url
endfunction

function! db#adapter#ssh#create_tunnel(url) abort
  call s:get_tunneled_url(a:url, v:true)
endfunction

function! db#adapter#ssh#canonicalize(url) abort
  let url = s:get_tunneled_url(a:url)
  return call(s:fn_name(l:url, 'canonicalize'), [l:url])
endfunction

function! db#adapter#ssh#interactive(url) abort
  let url = s:get_tunneled_url(a:url)
  return call(s:fn_name(l:url, 'interactive'), [l:url])
endfunction

function! db#adapter#ssh#filter(url) abort
  let url = s:get_tunneled_url(a:url)
  return call(s:fn_name(l:url, 'filter'), [l:url])
endfunction

function! db#adapter#ssh#auth_pattern() abort
  return '^ERROR 104[45]\|denied\|login\|auth\|not permitted\|ORA-01017'
endfunction

function! db#adapter#ssh#tables(url) abort
  let url = s:get_tunneled_url(a:url)
  return call(s:fn_name(l:url, 'tables'), [l:url])
endfunction

function! db#adapter#ssh#complete_opaque(url) abort
  return []
endfunction

function! db#adapter#ssh#complete_database(url) abort
  return []
endfunction
