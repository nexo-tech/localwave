
import { TracksList } from "@/components/TracksList";
import { screenPadding } from "@/constants/tokens";
import { trackTitleFilter } from "@/helpers/filter";
import { generateTracksListId } from "@/helpers/miscellaneous";
import { useNavigationSearch } from "@/hooks/useNavigationSearch";
import { useFavorites } from "@/store/library";
import { defaultStyles } from "@/styles";
import { useMemo } from "react";
import { ScrollView, View, Text, TouchableOpacity, Platform } from "react-native";
import { CloudStorage, CloudStorageProvider, useIsCloudAvailable } from 'react-native-cloud-storage';

CloudStorage.setProvider(
	Platform.select({
		ios: CloudStorageProvider.ICloud,
		default: CloudStorageProvider.ICloud,
	})
);
const ManageScreen = () => {
	const runMyLogin = () => {
		console.log("running my app")
	}
	const isCloudAvailable = useIsCloudAvailable()

	return (
		<View style={defaultStyles.container}>
			<View style={{ paddingTop: 150, width: "100%", flex: 1, height: "100%", }}>
				<View style={{ padding: 10 }}>
					<Text style={defaultStyles.text}>Cloud available: {isCloudAvailable ? "true" : "false"}</Text>
					<TouchableOpacity onPress={() => {
						runMyLogin();
					}} style={{ padding: 20 }}>
						<Text style={defaultStyles.text}>Run</Text>
					</TouchableOpacity>
				</View>
			</View>
		</View>
	);
};

export default ManageScreen;
