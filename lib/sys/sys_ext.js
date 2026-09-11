// The JavaScript implementation of the Pyking module declared in
// sys_ext.external.pyk. Node only: a browser has neither arguments nor
// an environment, which is why `sys` claims no web24/iweb24.
//
// `process.argv` is [node, script, ...arguments], so the program is
// argv[1] and its own arguments start at 2.
//
// The environment is read once, into an array, so that a name and its
// value always agree about which index they are.
const args = process.argv.slice(2);
const variables = Object.entries(process.env);

export function argument_count() {
  return args.length;
}

export function argument(i) {
  return args[i];
}

export function program() {
  return process.argv[1];
}

export function environment_count() {
  return variables.length;
}

export function environment_name(i) {
  return variables[i][0];
}

export function environment_value(i) {
  return variables[i][1] ?? "";
}
