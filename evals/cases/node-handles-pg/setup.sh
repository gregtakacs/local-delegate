cat > "$1/package.json" <<'J'
{ "name": "handles", "version": "0.0.0", "type": "module", "private": true,
  "scripts": { "test": "node --test" } }
J
printf '# handles\n' > "$1/README.md"
