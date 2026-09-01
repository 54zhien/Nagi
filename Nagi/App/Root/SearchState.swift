//
//  SearchState.swift
//  Nagi
//
//  State bridge between the persistent UIKit search control and SearchView.
//

import Observation

@MainActor
@Observable
final class SearchState {
    var query = ""
    var isPresented = false
}
