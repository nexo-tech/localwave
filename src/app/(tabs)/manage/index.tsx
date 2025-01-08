
import { TracksList } from "@/components/TracksList";
import { screenPadding } from "@/constants/tokens";
import { trackTitleFilter } from "@/helpers/filter";
import { generateTracksListId } from "@/helpers/miscellaneous";
import { useNavigationSearch } from "@/hooks/useNavigationSearch";
import { useFavorites } from "@/store/library";
import { defaultStyles } from "@/styles";
import { useMemo } from "react";
import { ScrollView, View, Text } from "react-native";

const ManageScreen = () => {

	return (
		<View style={defaultStyles.container}>
			<View style={{ paddingTop: 150, width: "100%", flex: 1, height: "100%", }}>
				<View style={{ padding: 10 }}>
					<Text style={defaultStyles.text}>Helsdadlo world</Text>
				</View>
			</View>
		</View>
	);
};

export default ManageScreen;
