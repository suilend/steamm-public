module steamm::utils;

use std::string::{Self, String, substring};
use std::ascii::{Self};
use std::type_name;

public(package) fun get_type_reflection<T>(): String {
    let t = string::utf8(ascii::into_bytes(
        type_name::into_string(type_name::get<T>())
    ));

    let delimiter = string::utf8(b"::");
    let package_delimiter_index = string::index_of(&t, &delimiter);
    let tail = substring(&t, package_delimiter_index + 2, string::length(&t));
    let module_delimiter_index = string::index_of(&tail, &delimiter);

    let type_name = substring(&tail, module_delimiter_index + 2, string::length(&tail));

    type_name
}
