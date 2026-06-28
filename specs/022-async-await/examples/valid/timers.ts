// setTimeout schedules callbacks on the event loop; they fire in delay order
// after the synchronous code, and run before the program exits. Callbacks may
// capture surrounding values.

function report(label: string, n: int): void {
  console.log(label);
  console.log(n);
}

function scheduleReport(label: string, n: int, ms: int): void {
  setTimeout(() => report(label, n), ms);
}

console.log("start");
scheduleReport("slow", 1, 30);
scheduleReport("fast", 2, 5);
console.log("scheduled");
