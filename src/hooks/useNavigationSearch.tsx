import { colors } from "@/constants/tokens";
import { useNavigation } from "expo-router";
import { useCallback, useLayoutEffect, useState } from "react";
import type { SearchBarProps } from "react-native-screens";

const defaultSearchOptions: SearchBarProps = {
	tintColor: colors.primary,
	hideWhenScrolling: false,
};

export const useNavigationSearch = ({
	searchBarOptions,
}: {
	searchBarOptions?: SearchBarProps;
}) => {
	const [search, setSearch] = useState("");

	const navigation = useNavigation();

	const handleOnChangeText: SearchBarProps["onChangeText"] = useCallback(
		({ nativeEvent: { text } }: { nativeEvent: { text: string } }) => {
			setSearch(text);
		},
		[],
	);

	useLayoutEffect(() => {
		navigation.setOptions({
			headerSearchBarOptions: {
				...defaultSearchOptions,
				...searchBarOptions,
				onChangeText: handleOnChangeText,
			},
		});
	}, [navigation, searchBarOptions, handleOnChangeText]);

	return search;
};
