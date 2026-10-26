#!/bin/bash
# AI agent on a Mac: pinned open-source Desktop Commander, isolated by a macOS user boundary,
# exposed to ChatGPT through an OpenAI Secure MCP Tunnel.
#
#   AGENT_USER  (hidden, non-admin)  runs Desktop Commander; full shell INSIDE its boundary
#   TUNNEL_USER (hidden, non-admin)  runs tunnel-client and alone holds the runtime key
#   tunnel-client -> sudo -n -u AGENT_USER <root-owned launcher> -> node desktop-commander
#
# Configure agent.conf first (copy agent.conf.example). Then, with sudo, in order:
#   check                read-only preflight, changes nothing
#   normalize-ownership  (external volume only) enable ownership and fix files stored as uid 99
#   install              users, ACLs, Desktop Commander, config, launcher, sudoers, tunnel profile, daemon (NOT started)
#   key                  paste a NEW Restricted runtime key (Tunnels Read + Use)
#   test                 local acceptance through the production chain; writes a receipt
#   start                verified tunnel-client copy, doctor, load the daemon
#   status | stop | keepawake | uninstall
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SELF_DIR/agent.conf"
HARNESS="$SELF_DIR/acceptance.py"

c_ok(){ printf '\033[32m🟢 %s\033[0m\n' "$*"; }
c_warn(){ printf '\033[33m🟡 %s\033[0m\n' "$*"; }
c_bad(){ printf '\033[31m🔴 %s\033[0m\n' "$*"; }
die(){ c_bad "$*"; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0 $*"; }
now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------- configuration ----------
TUNNEL_ID=""; WORKSPACE="/Users/Shared/ai-workspace"; FOUNDER=""
AGENT_USER="aiagent"; AGENT_UID=450; TUNNEL_USER="aitunnel"; TUNNEL_UID=451
if [ -f "$CONF" ]; then
  # shellcheck source=/dev/null
  . "$CONF"
fi
FOUNDER="${FOUNDER:-${SUDO_USER:-}}"
WORKSPACE="${WORKSPACE%/}"

AGENT_HOME="/Users/$AGENT_USER"; TUNNEL_HOME="/Users/$TUNNEL_USER"
DC_PKG="@wonderwhy-er/desktop-commander"
DC_VER="0.3.1"
DC_INTEGRITY="sha512-cx7KTscLF951adHmDLVCDIVTqJ/Bg1LtdRILZoo5wa/UMeyOfMAuOJOEBulNMKBKb5Xd3nHDQnB9aXroN9Fw5A=="
if [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew; else BREW=/usr/local; fi
NODE="$BREW/bin/node"; NPM="$BREW/bin/npm"; RG="$BREW/bin/rg"
TUNNEL_CLIENT_SRC="$BREW/bin/tunnel-client"
TC_DIR="/usr/local/libexec/ai-agent/tunnel-client"
TUNNEL_CLIENT="$TC_DIR/tunnel-client"
PROFILE="ai-agent-desktop"
LABEL="com.ai-governance.agent-desktop"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUDOERS="/etc/sudoers.d/ai-agent"
LAUNCHER="$AGENT_HOME/bin/dc-launch.sh"
ENTRY="$TUNNEL_HOME/bin/mcp-entry.sh"
KEYFILE="$TUNNEL_HOME/tunnel/runtime-key"
PROFILE_DIR="$TUNNEL_HOME/tunnel/profiles"
STATE_DIR="$TUNNEL_HOME/tunnel/state"
LOG_DIR="$TUNNEL_HOME/logs"
SETUP_STATE="/var/db/ai-agent"
RECEIPTS="$WORKSPACE/AI_AGENT_RECEIPTS"

RW_DIR="list,add_file,search,delete,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"
RW_FILE="read,write,append,execute,delete,readattr,writeattr,readextattr,writeextattr,readsecurity"
DENY_ACE="user:$AGENT_USER deny list,search,add_file,add_subdirectory,delete_child,readattr,readextattr,readsecurity,delete"
TRAVERSE_ACE="user:$AGENT_USER allow search"
NOWRITE_ACE="user:$AGENT_USER deny add_file,add_subdirectory,delete_child"

# Boundary root: the volume mount (/Volumes/<name>) or /Users/Shared.
boundary_root() {
  case "$WORKSPACE" in
    /Volumes/*/*) echo "/Volumes/$(echo "$WORKSPACE" | cut -d/ -f3)" ;;
    /Users/Shared/*) echo "/Users/Shared" ;;
    *) echo "" ;;
  esac
}
ROOT="$(boundary_root)"

plist_get(){ local t; t="$(mktemp)"; cat > "$t"; plutil -extract "$1" raw -o - "$t" 2>/dev/null || true; rm -f "$t"; }

# Ancestors from ROOT down to WORKSPACE's parent, one per line.
ancestors() {
  local rel="${WORKSPACE#"$ROOT"/}" cur="$ROOT" part
  echo "$cur"
  IFS='/' read -r -a parts <<< "$rel"
  for part in "${parts[@]:0:${#parts[@]}-1}"; do cur="$cur/$part"; echo "$cur"; done
}

# Entries beside the path to WORKSPACE (to be denied), one per line.
siblings() {
  local a next
  while IFS= read -r a; do
    next="${WORKSPACE#"$a"/}"; next="${next%%/*}"
    for e in "$a"/* "$a"/.[!.]*; do
      [ -e "$e" ] && [ ! -L "$e" ] || continue
      [ "$(basename "$e")" = "$next" ] && continue
      echo "$e"
    done
  done < <(ancestors)
}

# ---------- checks ----------
preflight() {
  local fail=0
  [ "$(uname -s)" = "Darwin" ] && c_ok "macOS $(sw_vers -productVersion 2>/dev/null)" || { c_bad "not macOS"; fail=1; }
  [ -n "$TUNNEL_ID" ] && c_ok "tunnel id set" || { c_bad "TUNNEL_ID empty — copy agent.conf.example to agent.conf and fill it in"; fail=1; }
  if [ -n "$FOUNDER" ] && [ "$FOUNDER" != "root" ] && id "$FOUNDER" >/dev/null 2>&1; then
    c_ok "founder user $FOUNDER (uid $(id -u "$FOUNDER"))"
  else c_bad "founder user unknown — run via sudo from your own account or set FOUNDER"; fail=1; fi
  if [ -z "$ROOT" ]; then
    c_bad "WORKSPACE must be on an external volume (/Volumes/<name>/...) or under /Users/Shared/ — not in a home folder"; fail=1
  elif [ -L "$ROOT" ]; then
    c_bad "$ROOT is a symlink (probably the startup disk) — use /Users/Shared/... instead"; fail=1
  else
    c_ok "boundary root $ROOT"
    if [ "$ROOT" != "/Users/Shared" ]; then
      local info perms; info="$(diskutil info -plist "$ROOT" 2>/dev/null || true)"
      perms="$(plist_get GlobalPermissionsEnabled <<<"$info")"
      if [ "$perms" = "true" ]; then c_ok "ownership enabled on $ROOT"
      else c_bad "'Ignore ownership' is ON for $ROOT — isolation would be void. Run: sudo $0 normalize-ownership"; fail=1; fi
    fi
  fi
  if [ -d "$WORKSPACE" ]; then c_ok "workspace $WORKSPACE"
  elif [ "$ROOT" = "/Users/Shared" ]; then c_warn "workspace $WORKSPACE will be created by install"
  else c_bad "workspace $WORKSPACE missing"; fail=1; fi

  if [ -x "$NODE" ] && "$NODE" -e 'const[a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=12)?0:1)'; then
    c_ok "node $("$NODE" -p process.versions.node)"
  else c_bad "node >= 22.12 needed (brew install node)"; fail=1; fi
  [ -x "$NPM" ] && c_ok "npm" || { c_bad "npm missing"; fail=1; }
  [ -x "$RG" ] && c_ok "ripgrep" || { c_bad "ripgrep missing (brew install ripgrep)"; fail=1; }
  [ -x "$TUNNEL_CLIENT_SRC" ] && c_ok "tunnel-client" || { c_bad "tunnel-client missing (brew install openai/tools/tunnel-client)"; fail=1; }
  /usr/bin/git --version >/dev/null 2>&1 && c_ok "git" || { c_bad "git missing (xcode-select --install)"; fail=1; }
  /usr/bin/python3 -c 'import sys;sys.exit(0 if sys.version_info>=(3,9) else 1)' 2>/dev/null \
    && c_ok "python3 >= 3.9" || { c_bad "python3 >= 3.9 missing (xcode-select --install)"; fail=1; }
  return $fail
}

ace_add(){ # path ace  (one entry, never follows symlinks)
  local p="$1" ace="$2"
  [ -L "$p" ] && return 0
  chmod -a "$ace" "$p" 2>/dev/null || true
  chmod +a "$ace" "$p"
  printf 'ONE\t%s\t%s\n' "$p" "$ace" >> "$SETUP_STATE/acl.log"
}

ace_tree(){ # dir user
  local d="$1" u="$2"
  find "$d" -type d -exec chmod -a "user:$u allow $RW_DIR" {} + 2>/dev/null || true
  find "$d" -type f -exec chmod -a "user:$u allow $RW_FILE" {} + 2>/dev/null || true
  find "$d" -type d -exec chmod +a "user:$u allow $RW_DIR" {} +
  find "$d" -type f -exec chmod +a "user:$u allow $RW_FILE" {} +
  printf 'TREE\t%s\t%s\n' "$d" "$u" >> "$SETUP_STATE/acl.log"
}

id_free(){
  ! dscl . -list /Users UniqueID | awk -v id="$1" '$2==id{f=1}END{exit f?0:1}' &&
  ! dscl . -list /Groups PrimaryGroupID | awk -v id="$1" '$2==id{f=1}END{exit f?0:1}'
}

mk_user(){ # name uid home
  local u="$1" id="$2" home="$3"
  if dscl . -read "/Users/$u" >/dev/null 2>&1; then
    [ "$(id -u "$u")" = "$id" ] || die "user $u exists with an unexpected uid"
    c_warn "user $u exists (reused)"; return
  fi
  id_free "$id" || die "uid/gid $id is taken — set another in agent.conf"
  dscl . -create "/Groups/$u"; dscl . -create "/Groups/$u" PrimaryGroupID "$id"
  dscl . -create "/Groups/$u" RealName "AI $u"
  dscl . -create "/Users/$u"
  dscl . -create "/Users/$u" UniqueID "$id"
  dscl . -create "/Users/$u" PrimaryGroupID "$id"
  dscl . -create "/Users/$u" UserShell /bin/zsh
  dscl . -create "/Users/$u" NFSHomeDirectory "$home"
  dscl . -create "/Users/$u" RealName "AI $u"
  dscl . -create "/Users/$u" IsHidden 1
  dscl . -create "/Users/$u" Password '*'
  mkdir -p "$home"; chown "$u:$u" "$home"; chmod 700 "$home"
  c_ok "user $u ($id) created, hidden, no login password"
}

# ---------- normalize-ownership (external volume) ----------
cmd_normalize() {
  need_root normalize-ownership
  [ -n "$ROOT" ] && [ "$ROOT" != "/Users/Shared" ] || die "only for a workspace on an external volume"
  local fid others; fid="$(id -u "$FOUNDER")"
  others="$(dscl . -list /Users UniqueID | awk -v f="$FOUNDER" -v a="$AGENT_USER" -v t="$TUNNEL_USER" '$2>=500 && $1!=f && $1!=a && $1!=t {print $1}')"
  [ -z "$others" ] || c_warn "other local users exist: $others — files you change to $FOUNDER will no longer be theirs"
  mkdir -p "$SETUP_STATE"; chmod 700 "$SETUP_STATE"
  diskutil enableOwnership "$ROOT"
  echo "Files not owned by $FOUNDER (system folders skipped), grouped by owner and top folder:"
  find "$ROOT" -xdev \( -name .Spotlight-V100 -o -name .fseventsd -o -name .Trashes -o -name .DocumentRevisions-V100 -o -name .TemporaryItems \) -prune \
    -o ! -uid "$fid" -print0 2>/dev/null | xargs -0 stat -f '%u|%N' \
    | awk -F'|' -v r="$ROOT" '{p=substr($2,length(r)+2); split(p,a,"/"); c["uid="$1"  "a[1]]++} END{for(k in c) print c[k], k}' | sort -rn | head -20
  printf "Change files stored as uid 99 (_unknown) to %s? Type YES (anything else = keep and disable ownership again): " "$FOUNDER"
  local a; read -r a
  if [ "$a" != "YES" ]; then diskutil disableOwnership "$ROOT"; die "unchanged; ownership disabled again"; fi
  find "$ROOT" -xdev -uid 99 -print0 > "$SETUP_STATE/uid99-before.list0"
  find "$ROOT" -xdev -uid 99 -exec chown -h "$fid" {} +
  find "$ROOT" -xdev -group 99 -exec chgrp -h staff {} +
  c_ok "done; remaining uid 99: $(find "$ROOT" -xdev -uid 99 | wc -l | tr -d ' ')"
  echo "    rollback list: $SETUP_STATE/uid99-before.list0  (sudo xargs -0 chown -h 99:99 < that file; diskutil disableOwnership $ROOT)"
}

# ---------- install ----------
cmd_install() {
  need_root install
  preflight || die "preflight failed — nothing changed"
  mkdir -p "$SETUP_STATE"; chmod 700 "$SETUP_STATE"
  echo "install_started $(now)" >> "$SETUP_STATE/history.log"
  if [ ! -d "$WORKSPACE" ]; then
    mkdir -p "$WORKSPACE"; chown "$FOUNDER:staff" "$WORKSPACE"; chmod 755 "$WORKSPACE"
    c_ok "workspace created"
  fi

  mk_user "$AGENT_USER" "$AGENT_UID" "$AGENT_HOME"
  mk_user "$TUNNEL_USER" "$TUNNEL_UID" "$TUNNEL_HOME"
  for u in "$AGENT_USER" "$TUNNEL_USER"; do
    for g in staff admin wheel; do
      dsmemberutil checkmembership -U "$u" -G "$g" 2>/dev/null | grep -q "is a member" \
        && die "$u is a member of $g — stopping. Clean up with: sudo $0 uninstall"
    done
  done
  c_ok "new users are not in staff/admin/wheel"

  # filesystem boundary
  ace_add "/Users/$FOUNDER" "$DENY_ACE"
  ace_add "$TUNNEL_HOME" "$DENY_ACE"
  : > "$SETUP_STATE/denied.list"
  local a e
  while IFS= read -r a; do ace_add "$a" "$TRAVERSE_ACE"; ace_add "$a" "$NOWRITE_ACE"; done < <(ancestors)
  while IFS= read -r e; do
    if ace_add "$e" "$DENY_ACE"; then echo "$e" >> "$SETUP_STATE/denied.list"; else c_warn "could not deny $e"; fi
  done < <(siblings)
  c_ok "path to the workspace is traverse-only; $(wc -l < "$SETUP_STATE/denied.list" | tr -d ' ') entries beside it denied"
  echo "    applying workspace ACL (symlinks are not followed)..."
  ace_tree "$WORKSPACE" "$AGENT_USER"
  ace_tree "$WORKSPACE" "$FOUNDER"
  c_ok "workspace: $AGENT_USER read/write, $FOUNDER keeps full control of agent-created files"

  # Desktop Commander, pinned, install scripts disabled
  local DC="$AGENT_HOME/dc"
  mkdir -p "$DC"; chown "$AGENT_USER:$AGENT_USER" "$DC"; chmod 700 "$DC"
  printf '{"name":"ai-agent-dc","version":"1.0.0","private":true,"dependencies":{"%s":"%s"}}\n' "$DC_PKG" "$DC_VER" > "$DC/package.json"
  chown "$AGENT_USER:$AGENT_USER" "$DC/package.json"
  local NPMENV=(env -i HOME="$AGENT_HOME" PATH="$BREW/bin:/usr/bin:/bin" LANG=C
    npm_config_cache="$DC/.npm-cache" npm_config_ignore_scripts=true npm_config_audit=false
    npm_config_fund=false npm_config_update_notifier=false npm_config_userconfig=/dev/null
    npm_config_registry=https://registry.npmjs.org)
  ( cd "$DC" && sudo -u "$AGENT_USER" "${NPMENV[@]}" "$NPM" install --package-lock-only --loglevel=error )
  local got; got="$(cd "$DC" && sudo -u "$AGENT_USER" "$NODE" -e \
    "const l=require('./package-lock.json');const e=l.packages['node_modules/$DC_PKG']||{};process.stdout.write(e.version+' '+e.integrity)")"
  [ "$got" = "$DC_VER $DC_INTEGRITY" ] || die "Desktop Commander integrity mismatch: $got"
  ( cd "$DC" && sudo -u "$AGENT_USER" "${NPMENV[@]}" "$NPM" ci --loglevel=error )
  c_ok "Desktop Commander $DC_VER installed (integrity pinned, install scripts disabled)"

  # locked config: root-owned, so the agent cannot loosen it through set_config_value
  local CFGD="$AGENT_HOME/.claude-server-commander"
  mkdir -p "$CFGD"
  cat > "$CFGD/config.json" <<EOF
{
  "telemetryEnabled": false,
  "allowedDirectories": ["$WORKSPACE"],
  "defaultShell": "/bin/zsh",
  "fileReadLineLimit": 2000,
  "fileWriteLineLimit": 500,
  "pendingWelcomeOnboarding": false,
  "welcomeOnboardingEligible": false,
  "blockedCommands": ["sudo","su","passwd","dscl","sysadminctl","dseditgroup","launchctl","diskutil","pmset","mkfs","dd","fdisk","shutdown","reboot","halt","csrutil","security"]
}
EOF
  chown -R root:wheel "$CFGD"; chmod 755 "$CFGD"; chmod 644 "$CFGD/config.json"
  c_ok "Desktop Commander config locked (telemetry off). The OS user boundary is the real guard."

  printf '[safe]\n\tdirectory = *\n[init]\n\tdefaultBranch = main\n' > "$AGENT_HOME/.gitconfig"
  chown "$AGENT_USER:$AGENT_USER" "$AGENT_HOME/.gitconfig"

  mkdir -p "$AGENT_HOME/bin"; chown root:wheel "$AGENT_HOME/bin"; chmod 755 "$AGENT_HOME/bin"
  cat > "$LAUNCHER" <<EOF
#!/bin/sh
[ "\$(id -un)" = "$AGENT_USER" ] || { echo "wrong user" >&2; exit 64; }
[ -d "$WORKSPACE" ] || { echo "workspace not available" >&2; exit 75; }
export HOME="$AGENT_HOME" USER="$AGENT_USER" LOGNAME="$AGENT_USER" SHELL=/bin/zsh LANG=en_US.UTF-8
export PATH="$BREW/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DESKTOP_COMMANDER_DISABLE_TELEMETRY=1
export DC_FLAG_URL="http://127.0.0.1:9/flags.json"
umask 007
cd "$WORKSPACE"
exec "$NODE" "$AGENT_HOME/dc/node_modules/$DC_PKG/dist/index.js" --no-onboarding
EOF
  chown root:wheel "$LAUNCHER"; chmod 755 "$LAUNCHER"

  mkdir -p "$TUNNEL_HOME/bin" "$PROFILE_DIR" "$STATE_DIR" "$LOG_DIR"
  printf '#!/bin/sh\nexec /usr/bin/sudo -n -u %s %s\n' "$AGENT_USER" "$LAUNCHER" > "$ENTRY"
  chown -R root:wheel "$TUNNEL_HOME/bin"; chmod 755 "$TUNNEL_HOME/bin" "$ENTRY"
  chown -R "$TUNNEL_USER:$TUNNEL_USER" "$TUNNEL_HOME/tunnel" "$LOG_DIR"; chmod 700 "$TUNNEL_HOME/tunnel" "$STATE_DIR" "$LOG_DIR"
  chown root:wheel "$PROFILE_DIR"; chmod 755 "$PROFILE_DIR"
  cat > "$PROFILE_DIR/$PROFILE.yaml" <<EOF
{
  "config_version": 1,
  "control_plane": {"base_url": "https://api.openai.com", "tunnel_id": "$TUNNEL_ID", "api_key": "file:$KEYFILE"},
  "health": {"listen_addr": "127.0.0.1:0", "url_file": "$STATE_DIR/health.url"},
  "admin_ui": {"open_browser": false},
  "log": {"level": "info", "format": "json", "file": "$LOG_DIR/tunnel.log"},
  "mcp": {"commands": [{"channel": "main", "command": "$ENTRY"}]}
}
EOF
  chown root:wheel "$PROFILE_DIR/$PROFILE.yaml"; chmod 644 "$PROFILE_DIR/$PROFILE.yaml"

  local tmp; tmp="$(mktemp)"
  printf '# the tunnel user may start ONLY the root-owned launcher as the agent user\nDefaults:%s !requiretty, !use_pty, !log_output, env_reset\n%s ALL=(%s) NOPASSWD: %s\n' \
    "$TUNNEL_USER" "$TUNNEL_USER" "$AGENT_USER" "$LAUNCHER" > "$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers validation failed"; }
  install -m 440 -o root -g wheel "$tmp" "$SUDOERS"; rm -f "$tmp"
  c_ok "sudoers: $TUNNEL_USER may start only the agent launcher"

  write_plist
  c_ok "LaunchDaemon written (NOT loaded)"
  echo "install_done $(now)" >> "$SETUP_STATE/history.log"
  echo; c_ok "install complete. Next: sudo $0 key  →  sudo $0 test  →  sudo $0 start"
}

write_plist() {
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>UserName</key><string>$TUNNEL_USER</string>
  <key>GroupName</key><string>$TUNNEL_USER</string>
  <key>ProgramArguments</key><array>
    <string>$TUNNEL_CLIENT</string><string>run</string><string>--profile</string><string>$PROFILE</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$TUNNEL_HOME</string>
    <key>PATH</key><string>$TC_DIR:$BREW/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>TUNNEL_CLIENT_PROFILE_DIR</key><string>$PROFILE_DIR</string>
    <key>TUNNEL_CLIENT_STATE_DIR</key><string>$STATE_DIR</string>
  </dict>
  <key>WorkingDirectory</key><string>$TUNNEL_HOME</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/stdout.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/stderr.log</string>
</dict></plist>
EOF
  chown root:wheel "$PLIST"; chmod 644 "$PLIST"; plutil -lint "$PLIST" >/dev/null
}

# Homebrew kegs can be private to their owner; the tunnel user runs a verified root-owned copy.
stage_client() {
  local src; src="$(dirname "$(dirname "$(realpath "$TUNNEL_CLIENT_SRC")")")/libexec"
  [ -x "$src/tunnel-client" ] || src="$(dirname "$(realpath "$TUNNEL_CLIENT_SRC")")"
  [ -x "$src/tunnel-client" ] || die "tunnel-client binary not found near $TUNNEL_CLIENT_SRC"
  mkdir -p "$(dirname "$TC_DIR")"; chown root:wheel "$(dirname "$TC_DIR")"; chmod 755 "$(dirname "$TC_DIR")"
  if [ -d "$TC_DIR" ] && diff -rq "$src" "$TC_DIR" >/dev/null 2>&1; then
    c_ok "tunnel-client copy up to date"
  else
    rm -rf "$TC_DIR.new"; ditto "$src" "$TC_DIR.new"
    chown -R root:wheel "$TC_DIR.new"; chmod -R u+rwX,go+rX,go-w "$TC_DIR.new"
    (cd "$src" && find . -type f -exec shasum -a 256 {} + | sort) > "$SETUP_STATE/tc.src.sha"
    (cd "$TC_DIR.new" && find . -type f -exec shasum -a 256 {} + | sort) > "$SETUP_STATE/tc.dst.sha"
    cmp -s "$SETUP_STATE/tc.src.sha" "$SETUP_STATE/tc.dst.sha" || { rm -rf "$TC_DIR.new"; die "copy hash mismatch"; }
    rm -rf "$TC_DIR.old"; if [ -d "$TC_DIR" ]; then mv "$TC_DIR" "$TC_DIR.old"; fi
    mv "$TC_DIR.new" "$TC_DIR"; rm -rf "$TC_DIR.old"
    c_ok "tunnel-client copied to $TC_DIR (SHA-256 of every file matches)"
    c_warn "the copy changed: (re)grant Full Disk Access to $TUNNEL_CLIENT"
  fi
  sudo -u "$TUNNEL_USER" test -x "$TUNNEL_CLIENT" && c_ok "$TUNNEL_USER can execute tunnel-client" \
    || die "$TUNNEL_USER cannot execute $TUNNEL_CLIENT"
  write_plist
}

cmd_key() {
  need_root key
  [ -d "$TUNNEL_HOME/tunnel" ] || die "run install first"
  echo "OpenAI Platform → API keys → Create → Restricted → Tunnels: Read + Use (NOT All, NOT an admin key)."
  printf "Paste the NEW runtime key (input hidden): "
  local k; IFS= read -rs k; echo
  [ -n "$k" ] || die "empty"
  umask 077; printf '%s' "$k" > "$KEYFILE"; unset k
  chown "$TUNNEL_USER:$TUNNEL_USER" "$KEYFILE"; chmod 400 "$KEYFILE"
  c_ok "key stored for $TUNNEL_USER only; value never printed"
}

cmd_test() {
  need_root test
  [ -f "$HARNESS" ] || die "acceptance.py not found next to this script"
  [ -f "$SETUP_STATE/denied.list" ] || die "run install first"
  local fp; fp="$(pgrep -u "$FOUNDER" -n Finder || pgrep -u "$FOUNDER" | head -1)"
  [ -n "$fp" ] || die "no process of $FOUNDER to use as a signal target"
  mkdir -p "$RECEIPTS"
  local rc; rc="$RECEIPTS/ACCEPTANCE_$(date -u +%Y%m%dT%H%M%SZ).json"
  local denied=() d
  while IFS= read -r d; do [ -d "$d" ] && denied+=(--denied-dir "$d"); done < "$SETUP_STATE/denied.list"
  /usr/bin/python3 -I "$HARNESS" \
    --launcher "$ENTRY" --spawn-user "$TUNNEL_USER" --agent-user "$AGENT_USER" \
    --workspaces "$WORKSPACE" --founder-home "/Users/$FOUNDER" "${denied[@]}" \
    --denied-file "$KEYFILE" --foreign-pid "$fp" --receipt "$rc"
  c_warn "this test runs under Terminal's privacy permissions; the daemon needs Full Disk Access (see README step 7)"
}

cmd_start() {
  need_root start
  [ -s "$KEYFILE" ] || die "no runtime key — run: sudo $0 key"
  mkdir -p "$SETUP_STATE"; chmod 700 "$SETUP_STATE"
  stage_client
  echo "tunnel-client doctor..."
  cd /
  sudo -u "$TUNNEL_USER" env -i HOME="$TUNNEL_HOME" PATH="$TC_DIR:$BREW/bin:/usr/bin:/bin" \
    TUNNEL_CLIENT_PROFILE_DIR="$PROFILE_DIR" TUNNEL_CLIENT_STATE_DIR="$STATE_DIR" \
    "$TUNNEL_CLIENT" doctor --profile "$PROFILE" --explain || die "doctor failed — not starting"
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  launchctl bootstrap system "$PLIST"
  echo "started $(now)" >> "$SETUP_STATE/history.log"
  for _ in $(seq 1 30); do
    if [ -s "$STATE_DIR/health.url" ]; then
      local u; u="$(cat "$STATE_DIR/health.url")"
      if curl -fsS --max-time 3 "${u%/}/readyz" >/dev/null 2>&1; then
        c_ok "tunnel ready"; cmd_status
        c_warn "if not done yet: System Settings → Privacy & Security → Full Disk Access → + → $TUNNEL_CLIENT, then: sudo $0 stop && sudo $0 start"
        return
      fi
    fi
    sleep 2
  done
  c_warn "not ready after 60s — check: sudo tail -50 $LOG_DIR/stderr.log"
}

cmd_status() {
  launchctl print "system/$LABEL" 2>/dev/null | grep -E '^\s*(state|pid|last exit code) ' || c_warn "$LABEL not loaded"
  if [ -s "$STATE_DIR/health.url" ]; then
    local u; u="$(cat "$STATE_DIR/health.url")"
    for p in healthz readyz health/mcp; do
      printf '    %-11s ' "$p"; curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 "${u%/}/$p" || echo down
    done
  fi
}

cmd_stop(){ need_root stop; launchctl bootout "system/$LABEL" && c_ok "stopped" || c_warn "was not loaded"; }

cmd_keepawake() {
  need_root keepawake
  pmset -a sleep 0 disksleep 0 autorestart 1 womp 1
  defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true
  c_ok "no sleep, restart after power loss, external disks mount without login"
}

cmd_uninstall() {
  need_root uninstall
  printf "Remove the agent setup (users, ACLs, daemon, sudoers)? Workspace files are kept. Type YES: "
  local a; read -r a; [ "$a" = "YES" ] || die "aborted"
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$SUDOERS"; rm -rf "$TC_DIR"
  if [ -f "$SETUP_STATE/acl.log" ]; then
    while IFS=$'\t' read -r kind p x; do
      [ -e "$p" ] || continue
      case "$kind" in
        ONE)  chmod -a "$x" "$p" 2>/dev/null || true ;;
        TREE) find "$p" -type d -exec chmod -a "user:$x allow $RW_DIR" {} + 2>/dev/null || true
              find "$p" -type f -exec chmod -a "user:$x allow $RW_FILE" {} + 2>/dev/null || true ;;
      esac
    done < "$SETUP_STATE/acl.log"
    mv "$SETUP_STATE/acl.log" "$SETUP_STATE/acl.log.removed.$(date +%s)"
  fi
  for u in "$AGENT_USER" "$TUNNEL_USER"; do
    pkill -u "$u" 2>/dev/null || true
    dscl . -delete "/Users/$u" 2>/dev/null || true
    dscl . -delete "/Groups/$u" 2>/dev/null || true
  done
  rm -rf "$AGENT_HOME" "$TUNNEL_HOME"
  echo "uninstalled $(now)" >> "$SETUP_STATE/history.log"
  c_ok "removed. Workspace content untouched. Remove the Full Disk Access entry in System Settings yourself."
}

case "${1:-}" in
  check)               preflight && c_ok "preflight PASS (nothing changed)" || { c_bad "preflight FAIL (nothing changed)"; exit 1; } ;;
  normalize-ownership) cmd_normalize ;;
  install)             cmd_install ;;
  key)                 cmd_key ;;
  test)                cmd_test ;;
  start)               cmd_start ;;
  status)              cmd_status ;;
  stop)                cmd_stop ;;
  keepawake)           cmd_keepawake ;;
  uninstall)           cmd_uninstall ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
