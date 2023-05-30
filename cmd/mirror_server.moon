
filter, SERVER, development = ...

SERVER or= "http://luarocks.org/repositories/rocks"
USER = "luarocks"

development = not not development

http = require "socket.http"

import parse_rockspec from require "helpers.uploaders"

import
  parse_manifest
  assert_request
  from require "helpers.mirror"

-- attempt to convert latin-1 chars to utf8
fix_encoding = (str) ->
  import insert from table
  buffer = {}
  changed = false

  bytes = [string.byte c for c in str\gmatch "."]
  for i, b in ipairs bytes
    prev = bytes[i - 1]
    after = bytes[i + 1]

    if b > 126 and (not prev or prev < 126) and (not after or after < 126)
      changed = true
      insert buffer, 194 -- insert latin1 leading byte

    insert buffer, b

  if changed
    table.concat([string.char(b) for b in *buffer]), true
  else
    str, false

log = do
  file = nil
  (str, skip_newline=false) ->
    unless file
      file = io.open("mirror.log", "w")

    unless skip_newline
      str = str .. "\n"

    file\write str
    io.stdout\write str

local user

mirror = ->
  log "Mirroring #{SERVER} to user: #{USER}, (dev: #{development})"
  import Users, LinkedModules from require "models"
  user = Users\find slug: USER

  import do_rockspec_upload, do_rock_upload from require "helpers.uploaders"

  unless user
    import generate_key from require "helpers.models"
    password = generate_key 30
    user = assert Users\create USER, password, "leafot+#{USER}@gmail.com"
    log "Created #{USER} with password #{password}"

  user_modules = user\get_modules!
  modules_by_name = {mod.name, mod for mod in *user_modules}

  manifest = assert_request "#{SERVER}/manifest"
  manifest = assert parse_manifest manifest

  for module_name, versions in pairs manifest.repository
    if filter and not module_name\match filter
      continue

    log "Processing #{module_name}"
    existing_mod = modules_by_name[module_name]
    existing_versions = if existing_mod
      {v.version_name, v for v in *existing_mod\get_versions!}
    else
      {}

    uploaded = 0

    for version_name, rocks in pairs versions
      existing_ver = existing_versions[version_name]

      log " * #{version_name} rockspec", true
      mod, version = if existing_ver
        log " - skipped"
        existing_mod, existing_ver
      else
        log " - uploading"
        rockspec, status = http.request "#{SERVER}/#{module_name}-#{version_name}.rockspec"

        if status != 200
          log "   Skipping due to missing rockspec"
          continue

        uploaded += 1

        rockspec, changed_enc = fix_encoding rockspec
        log "   Altered rockspec encoding" if changed_enc
        mod, version = assert do_rockspec_upload user, rockspec
        version\update(:development)
        mod, version

      existing_rocks = if existing_ver
        {rock.arch, rock for rock in *existing_ver\get_rocks!}
      else
        {}

      for {:arch} in *rocks
        continue if arch == "rockspec"
        log " * #{version_name} #{arch}", true
        if existing_rocks[arch]
          log " - skipped"
        else
          log " - uploading"
          uploaded += 1

          fname = "#{module_name}-#{version_name}.#{arch}.rock"
          rock = assert_request "#{SERVER}/#{fname}"
          do_rock_upload user, mod, version, fname, rock

    if existing_mod and uploaded > 0
      for link in *LinkedModules\select "where module_id = ?", existing_mod.id
        link\update_user!

mirror!
