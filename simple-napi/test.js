const addon = require('./lib');

console.log('--- simple-napi test ---\n');

// test hello()
const greeting = addon.hello();
console.log('hello():', greeting);
console.assert(greeting === 'Hello from N-API!', 'hello() failed');

// test add()
const sum = addon.add(3, 4);
console.log('add(3, 4):', sum);
console.assert(sum === 7, 'add(3, 4) failed');

const sumFloat = addon.add(1.5, 2.3);
console.log('add(1.5, 2.3):', sumFloat);
console.assert(Math.abs(sumFloat - 3.8) < 1e-10, 'add(1.5, 2.3) failed');

// test fibonacci()
console.log('fibonacci(0):', addon.fibonacci(0));
console.log('fibonacci(1):', addon.fibonacci(1));
console.log('fibonacci(10):', addon.fibonacci(10));
console.log('fibonacci(50):', addon.fibonacci(50));
console.assert(addon.fibonacci(0) === 0, 'fibonacci(0) failed');
console.assert(addon.fibonacci(1) === 1, 'fibonacci(1) failed');
console.assert(addon.fibonacci(10) === 55, 'fibonacci(10) failed');
console.assert(addon.fibonacci(50) === 12586269025, 'fibonacci(50) failed');

console.log('\nAll tests passed!');
