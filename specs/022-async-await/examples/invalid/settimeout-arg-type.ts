// setTimeout's delay must be an integer number of milliseconds.

function tick(): void {
  console.log(1);
}

setTimeout(tick, "soon");
