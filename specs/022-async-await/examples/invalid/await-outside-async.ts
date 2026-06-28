// `await` is not allowed inside a non-async function body.

async function p(): Promise<int> {
  return 1;
}

function bad(): void {
  await p();
}

bad();
