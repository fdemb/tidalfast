package tidal_tests

import "base:runtime"
import "core:testing"
import "core:time"

import app "../src/app"

// A reload keeps State only when its layout is the same. These layouts
// keep their size, which the size check alone lets through.
@(test)
state_layout_changes_change_the_version :: proc(t: ^testing.T) {
	same :: proc(a, b: typeid) -> bool {
		return app.layout_hash(type_info_of(a)) == app.layout_hash(type_info_of(b))
	}
	testing.expect(t, same(struct {a: i32, b: f32}, struct {a: i32, b: f32}))
	testing.expect(t, !same(struct {a: i32, b: f32}, struct {b: f32, a: i32}), "two fields swapped")
	testing.expect(t, !same(struct {a: i32, b: i32}, struct {a: i32, c: i32}), "a field renamed")
	testing.expect(t, !same(struct {a: i32}, struct {a: f32}), "a field retyped")
	// Two types named Row, one with its fields the other way round.
	rows_a, rows_b := rows_of_a(), rows_of_b()
	testing.expect(t, app.layout_hash(rows_a[0]) != app.layout_hash(rows_b[0]), "a field moved in what a slice points to")
	testing.expect(t, app.layout_hash(rows_a[1]) != app.layout_hash(rows_b[1]), "a field moved in what a pointer points to")

	start := time.tick_now()
	v := app.state_version()
	took := time.tick_since(start)
	testing.expect_value(t, app.state_version(), v)
	testing.expectf(t, took < 5 * time.Millisecond, "state_version took %v", took)
}

@(private = "file")
rows_of_a :: proc() -> [2]^runtime.Type_Info {
	Row :: struct {
		id:    i64,
		title: string,
	}
	return {type_info_of(struct {rows: []Row}), type_info_of(struct {row: ^Row})}
}

@(private = "file")
rows_of_b :: proc() -> [2]^runtime.Type_Info {
	Row :: struct {
		title: string,
		id:    i64,
	}
	return {type_info_of(struct {rows: []Row}), type_info_of(struct {row: ^Row})}
}
