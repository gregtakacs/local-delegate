cat > "$1/package.json" <<'J'
{ "name": "tip", "version": "0.0.0", "type": "module", "private": true, "scripts": { "test": "node --test" } }
J
printf '# tip\nA static, dependency-free tip splitter page.\n' > "$1/README.md"
