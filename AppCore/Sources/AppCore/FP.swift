import Foundation

public func equals<T>(_ lhs: T, _ rhs: T) -> Bool where T: Equatable {
    lhs == rhs
}
public func equals<T>(_ lhs: T?, _ rhs: T?) -> Bool where T: Equatable {
    lhs == rhs
}
public func equals<T>(_ value: T) -> (T) -> Bool where T: Equatable {
    value |> curry(equals)
}
public func equals<T>(_ value: T?) -> (T?) -> Bool where T: Equatable {
    value |> curry(equals)
}
public func notEquals<T>(_ lhs: T, _ rhs: T) -> Bool where T: Equatable {
    lhs != rhs
}
public func notEquals<T>(_ value: T) -> (T) -> Bool where T: Equatable {
    value |> curry(notEquals)
}

// Small util to be able to write the more descriptive
//     `.compactMap(identity)`
// instead of the somewhat confusing
//     `.compactMap { $0 }`
public func identity<T>(_ value: T) -> T {
    value
}

/// Ignores the data provided and returns a constant value.
/// Useful for passing a constant values to places that expect closures that provide
/// some data so you can compute a return value, but you don't need that input data.
///
/// For example:
/// `myIntArray.filter` will give you `Int` so you can return `Bool`
/// But if you have another variable in your scope that determines the `Bool`,
/// without having to evaluate the `Int`, you would usually do something like:
/// ```
/// myIntArray.filter { _ in shouldKeepIntegers }
/// ```
/// The problem with this approach is that you are capturing context in your closure,
/// which is usually not a problem for non-escaping functions or value types, but
/// you can still avoid the closure completely with function composition:
/// ```
/// myIntArray.filter(const(shouldKeepIntegers))
/// ```
///
/// Sibling to the function `func ignore<Ignore>(_ ignoredValue: Ignore) -> Void { }`
/// that would ignore the input but doesn't return any value back to the closure.
public func const<each Ignore, Return>(
    _ returnValue: Return
) -> (repeat each Ignore) -> Return {
    { (_: repeat each Ignore) in returnValue }
}

public func ignore<T>(_ t: T) { }

// Curries a given function that accepts two parameters
// into one that accepts the two parameters subsequently.
// Useful to break down a function that might be used later
// that we don't have all parameters at the time of calling.
// Eg: having a apiClient that takes a `AuthStore` that we
//     do not have now and a `Locale` that we do, so that
//     `Locale` can be passed to the curried function and
//     `AuthStore` passed later (partial application)
public func curry<A, B, C>(
    _ function: @escaping (A, B) -> C
)
-> (A)
-> (B)
-> C {
    { (a: A) -> (B) -> C in
        { (b: B) -> C in
            function(a, b)
        }
    }
}

public func unzurry<A, B>(
    _ function: @escaping (A) -> () -> B
)
-> (A)
-> B {
    { (a: A) -> B in
        function(a)()
    }
}

public func unzurry<A, B>(
    _ function: @escaping () -> (A) -> B
)
-> (A)
-> B {
    { (a: A) -> B in
        function()(a)
    }
}

public func flip<A, B, C>(
    _ function: @escaping (A, B) -> C
)
-> (B)
-> (A)
-> C {
    { (b: B) -> (A) -> C in
        { (a: A) -> C in
            function(a, b)
        }
    }
}

public func flip<A, B, C>(
    _ function: @escaping (A) -> (B) -> C
)
-> (B)
-> (A)
-> C {
    { (b: B) -> (A) -> C in
        { (a: A) -> C in
            function(a)(b)
        }
    }
}

// An helper to use the negation operator (!) functionally
// .filter(\.item >>> tabs.contains >>> not
public func not(_ value: Bool) -> Bool {
   !value
}

public func get<Root, Value>(_ keyPath: KeyPath<Root, Value>) -> (Root) -> Value {
    { a in
        a[keyPath: keyPath]
    }
}

// periphery:ignore
/// Functional setter (lens). Given a way to read/write access a property of type `Part`, in an
/// element of type `Whole` (using `WritableKeyPath<Whole, Part>`), and a functional that
/// transforms the current value into the new value, either by modifying it (`{ $0 + 1 }`} or
/// completely replacing it with a new constant value (`const(5)`), it gives back a function
/// `(Whole) -> Whole`, where you can provide any element that it will apply the transformation.
///
/// This is useful in many scenarios where you want to define the transformation of an element,
/// but you don't have the element yet, either because it's a stream in a Publisher, or you are
/// iterating over a collection, or you are using a composition.
///
/// The ability to either modify or replace the current value is very powerful, because you can
/// do things like uppercasing all surnames in a collection of people, or appending a String to
/// the end of all strings in an array, or even ignoring the current value and replacing it
/// completely for all elements in that array.
///
/// Two examples below, using array, but the same applies for Publisher, Result, Optional, etc.
///
/// ```swift
/// struct Person {
///     var name: String
///     var age: Int
/// }
///
/// let people = [
///     Person(name: "John", age: 42),
///     Person(name: "Paul", age: 42),
///     Person(name: "George", age: 42),
///     Person(name: "Ringo", age: 42)
/// ]
/// // Update all to 43 years
/// let updated = people.map(set(\.age, const(43)))
/// // is equivalent to people.map { $0.age = 43 }
///
/// // Increment 2 years for each person
/// let updated2 = people.map(set(\.age, 2 |> curry(+)))
/// // is equivalent to people.map { $0.age += 2 }
/// ```
///
/// The keypath must be Writable, so for structs please resolve to a `var` property. Class is
/// already writable.
///
public func set<Whole, Part>(
    _ keyPath: WritableKeyPath<Whole, Part>,
    _ transform: @escaping (Part) -> Part
) -> (Whole) -> Whole {
    set(
        get: { $0[keyPath: keyPath] },
        set: { whole, newPart in
            var mutableWhole = whole
            mutableWhole[keyPath: keyPath] = newPart
            return mutableWhole
        },
        transform
    )
}

private func set<Whole, Part>(
    get: @escaping (Whole) -> Part,
    set: @escaping (Whole, Part) -> Whole,
    _ transform: @escaping (Part) -> Part
) -> (Whole) -> Whole {
    { whole in
        let currentPart = get(whole)
        let newPart = transform(currentPart)
        return set(whole, newPart)
    }
}

public extension KeyPath {
    @inline(__always)
    static prefix func ^ (keyPath: KeyPath) -> (Root) -> Value {
        get(keyPath)
    }
}

public extension WritableKeyPath {
    // periphery:ignore
    static prefix func ^ (keyPath: WritableKeyPath) -> (@escaping (Value) -> Value)
    -> ((Root) -> Root) {
        { transform in
            set(keyPath, transform)
        }
    }
}

/// Given an input, applies it into multiple functions that takes that same input type
/// Examples:
/// - If you want the lowest and greatest elements of a `[Int]`:
/// ```swift
/// let fn: ([Int]) -> (Int?, Int?) = fanout({ $0.min() }, { $0.max() })
/// let (min, max) = fn([9, 3, 5, 1, 16, 2])
/// ```
/// - If you want a tuple with only the name and age of a Person:
/// ```swift
/// let fn = fanout(^\Person.name, ^\Person.age)
/// fn(.fixture())
/// ```
/// - If you want to compare Equality of only name and age of a Person:
/// ```swift
/// let fn = fanout(^\Person.name, ^\Person.age)
/// let haveEqualNamesAndAges = (lhs |> b, rhs |> b) |> (==)
/// ```
/// - Parameter functions: one or many functions that transform the same type of input
/// - Returns: a unified function that applies all given functions and returns a tuple
///            with all the results
public func fanout<Input, each Output>(
    _ functions: repeat (@escaping (Input) -> each Output)
) -> (Input) -> (repeat each Output) {
    { input in
        (repeat (each functions)(input))
    }
}

/// Given a function that transforms A into B, it will generate a function that transforms
/// a tuple of As into a tuple of Bs. This is the 2-ary version
/// - Parameter function: (A) - B
/// - Returns: a function that transforms (A, A) into (B, B)
public func mapTuple2<A, B>(
    _ function: @escaping (A) -> B
) -> (A, A) -> (B, B) {
    { input1, input2 in
        (function(input1), function(input2))
    }
}

/// Cast an object to the desired type. The origin type must be
/// a subclass of the destination type, eg APIClientError > Swift.Error
public func castAs<T>(_ destinationType: T.Type) -> (_ originObject: T) -> T {
    { $0 as T }
}

/// Convenience to cast a custom *Error to Swift.Error.
public func castAsSwiftError<CustomError: Error>(error: CustomError) -> Error {
    castAs(Error.self)(error)
}

/// Transform a pair of value and a method signature with a parameter of the exact same type into closure.
/// It can be used to compose a particular function using |> operator, eg
/// 5.0 |> Int.init |> with(3, using: Int.advanced) // 8
public func with<T, Y>(_ value: T, using function: @escaping (Y) -> ((T) -> Y)) -> ((Y) -> Y) {
    { function($0)(value) }
}

/// Allows for transforming a function which returns an optional type to a function which returns non-optional type
/// by passing a fallback of a given type.
///
/// For example:
/// ```
/// let f: (String) -> Character? = \.first
/// let f: (String) -> Character = \.first >>> or("X")
/// ```
/// When `f` function changes its type to return a non-optional, a default value has to be provided. This can be
/// achieved by using the `or` function and `>>>` operator:
public func or<A>(_ fallback: A) -> (A?) -> A {
    { optional in
        optional ?? fallback
    }
}

/// Allows for transforming a function to a similar function but with more arguments by specyfing
/// which one has to be used. The other arguments will be ignored.
///
/// Example:
/// ```
/// let f: (String) -> Character? = \.first
/// let f: (String, Int) -> Character? = \.first |> usingArg(\.0)
/// ```
/// When `f` function changes its type and introduces another argument, the key path cannot be used anymore as
/// it uses only a single argument. However, it still can be changed to use `usingArg` function and `|>` operator:
public func usingArg<Arg1, Arg2, Picked, Return>(
    _ pickArgument: @escaping ((Arg1, Arg2)) -> Picked
) -> (@escaping (Picked) -> Return) -> (Arg1, Arg2) -> Return {
    { f in
        { f(pickArgument(($0, $1))) }
    }
}

// Passes the value to the function (and executes it)
// eg: `5 |> functionThatConvertsIntsToStrings`
public func |> <T, U>(x: T, f: (T) -> U) -> U {
    f(x)
}

import Combine
// <Functor>

// https://hackage.haskell.org/package/base-4.20.0.1/docs/Data-Functor.html#v:-60--36-
// (<$) :: a -> f b -> f a infixl 4
public func <£ <A, B>(a: A, fb: [B]) -> [A] {
    [A](repeating: a, count: fb.count)
}
public func <£ <A, B>(a: A, fb: B?) -> A? {
    fb.map(a |> const)
}
public func <£ <A, B, E: Error>(a: A, fb: Result<B, E>) -> Result<A, E> {
    fb.map(a |> const)
}
public func <£ <A, PB: Publisher, E: Error>(a: A, fb: PB) -> any Publisher<A, E> where PB.Failure == E {
    fb.map(a |> const)
}

// https://hackage.haskell.org/package/base-4.20.0.1/docs/Data-Functor.html#v:-36--62-
// ($>) :: Functor f => f a -> b -> f b infixl 4
public func £> <A, B>(fa: [A], b: B) -> [B] {
    [B](repeating: b, count: fa.count)
}
public func £> <A, B>(fa: A?, b: B) -> B? {
    fa.map(b |> const)
}
public func £> <A, B, E: Error>(fa: Result<A, E>, b: B) -> Result<B, E> {
    fa.map(b |> const)
}
public func £> <B, FA: Publisher, E: Error>(fa: FA, b: B) -> any Publisher<B, E> where FA.Failure == E {
    fa.map(b |> const)
}

// https://hackage.haskell.org/package/base-4.20.0.1/docs/Data-Functor.html#v:-60--36--62-
// (<$>) :: Functor f => (a -> b) -> f a -> f b infixl 4
public func <£> <A, B>(_ transform: (A) -> B, fa: [A]) -> [B] {
    fa.map(transform)
}
public func <£> <A, B>(_ transform: (A) -> B, fa: A?) -> B? {
    fa.map(transform)
}
public func <£> <A, B, E: Error>(_ transform: (A) -> B, fa: Result<A, E>) -> Result<B, E> {
    fa.map(transform)
}
public func <£> <A, B, FA: Publisher, E: Error>(_ transform: @escaping (A) -> B, fa: FA) -> any Publisher<B, E> where FA.Output == A, FA.Failure == E{
    fa.map(transform)
}

// https://hackage.haskell.org/package/base-4.20.0.1/docs/Data-Functor.html#v:-60--38--62-
// (<&>) :: Functor f => f a -> (a -> b) -> f b infixl 1
public func <&> <A, B>(fa: [A], _ transform: (A) -> B) -> [B] {
    fa.map(transform)
}
public func <&> <A, B>(fa: A?, _ transform: (A) -> B) -> B? {
    fa.map(transform)
}
public func <&> <A, B, E: Error>(fa: Result<A, E>, _ transform: (A) -> B) -> Result<B, E> {
    fa.map(transform)
}
public func <&> <A, B, FA: Publisher, E: Error>(fa: FA, _ transform: @escaping (A) -> B) -> any Publisher<B, E> where FA.Output == A, FA.Failure == E{
    fa.map(transform)
}

// </Functor>

public func >=> <A, B, C>(f: @escaping (A) -> B?, g: @escaping (B) -> C?) -> (A) -> C? {
    f >>> { $0.flatMap(g) }
}

public func >=> <B, C>(f: @escaping () -> B?, g: @escaping (B) -> C?) -> () -> C? {
    f >>> { $0.flatMap(g) }
}

// Merges two functions together, effectively resulting
// in a function that has the input of the first function
// and the output of the second.
// eg: `intToDoubleConverter >>> doubleToStringConverter`
//     `(Int) -> Double >>> (Double) -> String`
//     with and end result of `intToString`, aka `(Int) -> String`
public func >>> <A, B, C>(f: @escaping (A) -> B, g: @escaping (B) -> C) -> (A) -> C {
    { g(f($0)) }
}

public func >>> <B, C>(f: @escaping () -> B, g: @escaping (B) -> C) -> () -> C {
    { g(f()) }
}


public func <<< <A, B, C>(g: @escaping (B) -> C, f: @escaping (A) -> B) -> (A) -> C {
    { g(f($0)) }
}

public func <<< <B, C>(g: @escaping (B) -> C, f: @escaping () -> B) -> () -> C {
    { g(f()) }
}

// periphery:ignore:all - Used by tests only
import Foundation

/// It returns a function that calls `fatalError`, regardless of the parameters provided.
/// All the input parameters will be ignored.
///
/// Example:
/// ```
/// init(
///     fn: @escaping (String, Int) -> AnyPublisher<String, Never> = fail("Mock not implemented")
/// ) -> Mock
/// ```
///
/// **Be careful with this function in a production code, it will crash the app if not overriden.**
public func fail<T, each U>(
    _ message: String,
    file: StaticString = #file,
    line: UInt = #line
) -> (repeat each U) -> T {
    { (_: repeat each U) -> T in
        fatalError(message, file: file, line: line)
    }
}

public protocol With {}

public extension With where Self: Any {
    /// Makes it available to set properties with closures just after initializing and copying the value types.
    ///
    ///     let frame = CGRect().with {
    ///       $0.origin.x = 10
    ///       $0.size.width = 100
    ///     }
    @discardableResult func with(_ block: (inout Self) throws -> Void) rethrows -> Self {
        var copy = self
        try block(&copy)
        return copy
    }
}

// Execute a closure if and only if the value can be unwrapped.
// Eg: myOptional.then { unwrappedValue in print(unwrappedValue) }
public extension Optional {
    @discardableResult func then(_ f: (Wrapped) -> Void, otherwise: () -> Void = {}) -> Bool {
        if let wrapped = self {
            f(wrapped)
            return true
        }
        else {
            otherwise()
            return false
        }
    }
}

// Something to help with readability and descriptiveness
// eg: `if myOptionalValue.isNotNil { foo() }`
public extension Optional {
    var isNil: Bool {
        self == nil
    }

    var isNotNil: Bool {
        self != nil
    }
}

/// Determine whether an optional String is nil or empty.
public extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        guard let wrapped = self else { return true }
        return wrapped.isEmpty
    }
}

public extension Optional where Wrapped: Collection {
    init(ifEmpty c: Wrapped) {
        self = c.isEmpty ? nil : .some(c)
    }
}

public extension Optional {
    fileprivate struct UnwrapError: Error {}

    func fold<A>(_ fn: (Wrapped) -> A, _ fallback: () -> A) -> A {
        map(fn) ?? fallback()
    }

    /// Similar to zip(array1, array2) and Publishers.Zip(p1, p2), it will
    /// try to unwrap both sides, if any is nil, return nil. If both are
    /// present, the return will be a tuple with the unwrapped values.
    /// Typically used together with map:
    /// ```
    /// Optional.zip(possibleInteger1, possibleInteger2).map(+) ?? fallback
    /// Optional.zip(possibleInteger1, possibleInteger2, possibleInteger3, possibleInteger4).map(+) ?? fallback
    /// ```
    static func zip<SecondWrapped, each AdditionalWrapped>(
        _ firstOptional: Wrapped?,
        _ secondOptional: SecondWrapped?,
        _ additionalOptional: repeat (each AdditionalWrapped)?
    ) -> (Wrapped, SecondWrapped, repeat each AdditionalWrapped)? {
        func unwrap<T>(_ t: T?) throws -> T {
            guard let t else { throw UnwrapError() }
            return t
        }

        do {
            return try (
                unwrap(firstOptional),
                unwrap(secondOptional),
                repeat unwrap(each additionalOptional)
            )
        } catch {
            return nil
        }
    }
}

public func ^ (lhs: Float, rhs: Float) -> Float { pow(lhs, rhs) }
public func ^ (lhs: Double, rhs: Double) -> Double { pow(lhs, rhs) }
public func ++ <L>(lhs: Array<L>, rhs: L) -> Array<L> { lhs + [rhs] }
public func ++ (lhs: String, rhs: String) -> String { lhs + rhs }
public func ++ (lhs: String, rhs: Character) -> String { lhs + String(rhs) }

// https://rosettacode.org/wiki/Operator_precedence
// https://developer.apple.com/documentation/swift/operator-declarations

// 10: Function application
precedencegroup FunctionApplication {
    associativity: left
    higherThan: FunctionCompositionForward
}
infix operator |>: FunctionApplication

// 9: Function composition
precedencegroup FunctionCompositionForward {
    associativity: left
    higherThan: FunctionCompositionBackwards
}

precedencegroup FunctionCompositionBackwards {
    associativity: right
    higherThan: BitwiseShiftPrecedence
}

infix operator >>>: FunctionCompositionForward
infix operator <<<: FunctionCompositionBackwards // Haskell "point" operator

// 8.5: BitwiseShiftPrecedence >>

// 8: Power

precedencegroup PowerPrecedence {
    associativity: right
    lowerThan: BitwiseShiftPrecedence
    higherThan: MultiplicationPrecedence
}

infix operator ^: PowerPrecedence

// 7: MultiplicationPrecedence * /

// 6: AdditionPrecedence + -

// 5: Append to list

precedencegroup AppendToList {
    associativity: right
    lowerThan: AdditionPrecedence
    higherThan: RangeFormationPrecedence
}

infix operator ++: AppendToList

// 4.8: RangeFormationPrecedence ... ..<

// 4.5: CastingPrecedence as?

// 4.2: NilCoalescingPrecedence ??

// 4: ComparisonPrecedence == <=

// 4: Functor Ops

precedencegroup FunctorOps {
    associativity: left
    lowerThan: NilCoalescingPrecedence
    higherThan: LogicalConjunctionPrecedence
}

//          (<$) :: Functor f => a -> f b -> f a
//          ($>) :: Functor f => f a -> b -> f b infixl 4
//          (<$>) :: Functor f => (a -> b) -> f a -> f b infixl 4
//          (<&>) :: Functor f => f a -> (a -> b) -> f b infixl 1
//          (<$) :: a -> f b -> f a infixl 4
infix operator <£>: FunctorOps
infix operator £>: FunctorOps
infix operator <£: FunctorOps
infix operator <&>: FunctorOps


// 3: LogicalConjunctionPrecedence &&

// 2: LogicalDisjunctionPrecedence ||

// 1: Monadic ops >=> >>= =<< <|>

precedencegroup KleisliCompositionLeft {
    associativity: left
    lowerThan: LogicalDisjunctionPrecedence
    higherThan: KleisliCompositionRight
}

precedencegroup KleisliCompositionRight {
    associativity: right
    higherThan: TernaryPrecedence
}

infix operator >=>: KleisliCompositionLeft
infix operator >>=: KleisliCompositionLeft

infix operator <|>: KleisliCompositionRight
infix operator =<<: KleisliCompositionRight


// 0.5: TernaryPrecedence ?:

// 0: Parentheses

// -1: AssignmentPrecedence =

prefix operator ^
