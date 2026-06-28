class Account {
  private balance: int;
  constructor(start: int) {
    this.balance = start;
  }
}

let a = new Account(100);
console.log(a.balance);
