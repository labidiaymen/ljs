// Records, enums, arrays, for...of, and template literals.

enum Category { Food, Tool, Book }

interface Item {
  name: string;
  price: int;
  category: Category;
}

function describe(item: Item): string {
  return `${item.name}: $${item.price}`;
}

let items: Item[] = [
  { name: "apple", price: 2, category: Category.Food },
  { name: "hammer", price: 15, category: Category.Tool },
  { name: "novel", price: 9, category: Category.Book },
];

let total = 0;
for (const item of items) {
  console.log(describe(item));
  total += item.price;
}

console.log(`total: $${total}`);
