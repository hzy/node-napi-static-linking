#include <napi.h>
#include <string>

// 返回 "Hello from N-API!"
Napi::String Hello(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  return Napi::String::New(env, "Hello from N-API!");
}

// 两数相加: add(a, b) -> number
Napi::Number Add(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();

  if (info.Length() < 2) {
    Napi::TypeError::New(env, "Expected 2 arguments").ThrowAsJavaScriptException();
    return Napi::Number::New(env, 0);
  }

  if (!info[0].IsNumber() || !info[1].IsNumber()) {
    Napi::TypeError::New(env, "Arguments must be numbers").ThrowAsJavaScriptException();
    return Napi::Number::New(env, 0);
  }

  double a = info[0].As<Napi::Number>().DoubleValue();
  double b = info[1].As<Napi::Number>().DoubleValue();

  return Napi::Number::New(env, a + b);
}

// 计算斐波那契数列第 n 项 (演示 CPU 密集计算)
Napi::Number Fibonacci(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();

  if (info.Length() < 1 || !info[0].IsNumber()) {
    Napi::TypeError::New(env, "Expected a number argument").ThrowAsJavaScriptException();
    return Napi::Number::New(env, 0);
  }

  int n = info[0].As<Napi::Number>().Int32Value();

  // 简单的迭代实现
  if (n <= 0) return Napi::Number::New(env, 0);
  if (n == 1) return Napi::Number::New(env, 1);

  long long prev = 0, curr = 1;
  for (int i = 2; i <= n; i++) {
    long long next = prev + curr;
    prev = curr;
    curr = next;
  }

  return Napi::Number::New(env, static_cast<double>(curr));
}

// 模块初始化
Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set(Napi::String::New(env, "hello"),
              Napi::Function::New(env, Hello));
  exports.Set(Napi::String::New(env, "add"),
              Napi::Function::New(env, Add));
  exports.Set(Napi::String::New(env, "fibonacci"),
              Napi::Function::New(env, Fibonacci));
  return exports;
}

NODE_API_MODULE(simple_napi, Init)
