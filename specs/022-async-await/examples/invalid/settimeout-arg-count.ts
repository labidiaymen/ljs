// setTimeout requires exactly a callback and a delay.

function tick(): void {
  console.log(1);
}

setTimeout(tick);
